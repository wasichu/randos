defmodule Tui.Model do
  @moduledoc """
  What the TUI shows, derived from server messages and key presses. Pure.

  The participant's state machine lives on the server (see the protocol doc,
  `docs/architecture/participant_channel.md` in the server repo). This model
  only keeps the latest server `state`, the language form for `find`, and a
  short event log. Every function returns `{model, commands}`, where commands
  are channel pushes for the caller to send: `{:push, event, payload}`.

  `audio?` says whether this client can carry call audio (its media helper
  is running). `find` sends it, so the server only pairs compatible
  clients. With audio, WebRTC signals are the media layer's business
  (`Tui.Media.State`). Without it, a peer's `offer` gets `end_call`, which
  ends the call with this client going idle and only the peer requeued.
  """

  @max_log 30

  @type status :: :connecting | :idle | :looking | :in_call | :extension_pending
  @type command :: {:push, String.t(), map()}

  @type t :: %__MODULE__{
          connection: :connecting | :connected,
          languages: [%{code: String.t(), name: String.t()}],
          speaks: non_neg_integer(),
          listens: non_neg_integer(),
          adult_acknowledged?: boolean(),
          audio?: boolean(),
          focus: :speaks | :listens | :ack,
          status: status() | nil,
          webrtc_role: String.t() | nil,
          error: String.t() | nil,
          call: map() | nil,
          now_ms: integer(),
          log: [String.t()]
        }

  defstruct connection: :connecting,
            languages: [],
            speaks: 0,
            listens: 1,
            adult_acknowledged?: false,
            audio?: false,
            focus: :speaks,
            status: nil,
            webrtc_role: nil,
            error: nil,
            call: nil,
            now_ms: 0,
            log: []

  @statuses %{
    "idle" => :idle,
    "looking" => :looking,
    "connecting" => :connecting,
    "in_call" => :in_call,
    "extension_pending" => :extension_pending
  }

  @spec new(integer()) :: t()
  def new(now_ms \\ 0), do: %__MODULE__{now_ms: now_ms}

  ## Server messages

  @doc "Whether this client can carry call audio (sent with `find`)."
  @spec set_audio(t(), boolean()) :: t()
  def set_audio(model, audio?), do: %{model | audio?: audio?}

  @doc "The join reply: initial state and the supported languages."
  @spec joined(t(), map()) :: {t(), [command()]}
  def joined(model, %{"state" => state, "languages" => languages}) do
    first_join? = model.languages == []

    model = %{
      model
      | connection: :connected,
        languages: Enum.map(languages, &%{code: &1["code"], name: &1["name"]}),
        # A (re)join is a brand-new participant; don't log it as a transition.
        status: nil
    }

    model =
      if first_join?,
        do: log(model, "connected"),
        else: log(model, "reconnected as a new participant")

    {put_state(model, state), []}
  end

  @spec disconnected(t()) :: {t(), [command()]}
  def disconnected(model) do
    {log(%{model | connection: :connecting}, "disconnected; reconnecting"), []}
  end

  @doc "A server push on the participant channel."
  @spec push(t(), String.t(), map()) :: {t(), [command()]}
  def push(model, "state", state), do: {put_state(model, state), []}

  def push(model, "ice_servers", _payload), do: {model, []}

  def push(%{audio?: false} = model, "signal", %{"type" => "offer"}) do
    # end_call (not connection_failed): it ends the call with us stopping, so
    # only the peer is requeued. Any other ending requeues both of us, and
    # we'd rematch and refuse again in a loop.
    model =
      log(
        model,
        "peer offered audio; this client has none, so the call ended (Enter to look again)"
      )

    {model, [{:push, "end_call", %{}}]}
  end

  def push(model, "signal", _signal), do: {model, []}
  def push(model, _event, _payload), do: {model, []}

  @doc "A reply to one of our pushes; only errors are worth showing."
  @spec reply(t(), String.t(), {:ok, map()} | {:error, map()}) :: {t(), [command()]}
  def reply(model, event, {:error, %{"reason" => reason}}),
    do: {log(model, "#{event} refused: #{reason}"), []}

  def reply(model, _event, _reply), do: {model, []}

  @spec tick(t(), integer()) :: t()
  def tick(model, now_ms), do: %{model | now_ms: now_ms}

  ## Keys

  @doc "A key press (ex_ratatui key code string) in the current status."
  @spec key(t(), String.t()) :: {t(), [command()]}
  def key(%{connection: :connecting} = model, _key), do: {model, []}

  def key(%{status: :idle} = model, key) do
    case key do
      k when k in ["tab", "down"] -> {%{model | focus: next_focus(model.focus)}, []}
      "up" -> {%{model | focus: prev_focus(model.focus)}, []}
      "left" -> {cycle_language(model, -1), []}
      "right" -> {cycle_language(model, 1), []}
      " " -> {%{model | adult_acknowledged?: not model.adult_acknowledged?}, []}
      "enter" -> {model, [{:push, "find", find_payload(model)}]}
      _ -> {model, []}
    end
  end

  def key(%{status: :looking} = model, k) when k in ["c", "esc"],
    do: {model, [{:push, "cancel_search", %{}}]}

  def key(%{status: s} = model, "e") when s in [:connecting, :in_call],
    do: {model, [{:push, "end_call", %{}}]}

  def key(%{status: s} = model, "n") when s in [:connecting, :in_call],
    do: {model, [{:push, "next", %{}}]}

  def key(%{status: :extension_pending} = model, "y"),
    do: {model, [{:push, "vote", %{vote: "continue"}}]}

  def key(%{status: :extension_pending} = model, k) when k in ["n", "e"],
    do: {model, [{:push, "vote", %{vote: "end"}}]}

  def key(model, _key), do: {model, []}

  ## Derived view data

  @spec language_name(t(), :speaks | :listens) :: String.t()
  def language_name(%{languages: []}, _field), do: "…"
  def language_name(model, field), do: Enum.at(model.languages, Map.fetch!(model, field)).name

  @doc "Seconds left in the current segment or vote, if any."
  @spec seconds_left(t()) :: non_neg_integer() | nil
  def seconds_left(
        %{call: %{"status" => "extension_pending", "extension_deadline_unix_ms" => d}} = m
      )
      when is_integer(d),
      do: max(0, div(d - m.now_ms + 999, 1000))

  def seconds_left(%{call: %{"call_deadline_unix_ms" => d}} = m) when is_integer(d),
    do: max(0, div(d - m.now_ms + 999, 1000))

  def seconds_left(_model), do: nil

  ## Helpers

  defp put_state(model, state) do
    # Unknown statuses (a newer server) keep the current one rather than crash.
    status = Map.get(@statuses, state["status"], model.status)

    updated = %{
      model
      | status: status,
        webrtc_role: state["webrtc_role"],
        error: state["error"],
        call: state["call"]
    }

    cond do
      state["error"] && state["error"] != model.error -> log(updated, "error: #{state["error"]}")
      status != model.status and model.status != nil -> log(updated, status_line(status))
      true -> updated
    end
  end

  defp status_line(:idle), do: "idle"
  defp status_line(:looking), do: "looking for a rando"
  defp status_line(:connecting), do: "matched; connecting"
  defp status_line(:in_call), do: "in call"
  defp status_line(:extension_pending), do: "time is up: continue? (y/n)"

  # Without audio the server pairs us only with other text-only clients,
  # never with a browser user who would sit through a silent call.
  defp find_payload(model) do
    %{
      speaks: Enum.at(model.languages, model.speaks).code,
      listens: Enum.at(model.languages, model.listens).code,
      adult_acknowledged: model.adult_acknowledged?,
      audio: model.audio?
    }
  end

  defp cycle_language(%{focus: field} = model, step) when field in [:speaks, :listens] do
    count = length(model.languages)
    if count == 0, do: model, else: Map.update!(model, field, &Integer.mod(&1 + step, count))
  end

  defp cycle_language(model, _step), do: model

  defp next_focus(:speaks), do: :listens
  defp next_focus(:listens), do: :ack
  defp next_focus(:ack), do: :speaks

  defp prev_focus(:speaks), do: :ack
  defp prev_focus(:listens), do: :speaks
  defp prev_focus(:ack), do: :listens

  defp log(model, line), do: %{model | log: Enum.take([line | model.log], @max_log)}
end
