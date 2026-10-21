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

  @typedoc """
  `speaks` is a language code; `hears` the codes the person is happy to
  hear. The speaking language starts checked, and choosing another speaking
  language checks it instead (`auto_hears` is the one checked that way, until
  the person touches it). `hears_cursor` is the language the hearing row
  points at (space toggles it).
  """
  @type t :: %__MODULE__{
          connection: :connecting | :connected,
          languages: [%{code: String.t(), name: String.t()}],
          speaks: String.t(),
          hears: [String.t()],
          hears_cursor: non_neg_integer(),
          auto_hears: String.t() | nil,
          adult_acknowledged?: boolean(),
          audio?: boolean(),
          focus: :speaks | :hears | :ack,
          status: status() | nil,
          webrtc_role: String.t() | nil,
          error: String.t() | nil,
          call: map() | nil,
          now_ms: integer(),
          log: [String.t()]
        }

  defstruct connection: :connecting,
            languages: [],
            speaks: "en",
            hears: ["en"],
            hears_cursor: 0,
            auto_hears: "en",
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

  @doc """
  The form as the person left it last time (`Tui.Config`): speaking and
  hearing languages and the 18+ acknowledgment. Codes the server doesn't
  offer are dropped when its languages arrive (`joined/2`).
  """
  @spec restore(t(), map()) :: t()
  def restore(model, saved) do
    speaks = if is_binary(saved["speaks"]), do: saved["speaks"], else: model.speaks

    hears =
      case saved["hears"] do
        [_ | _] = codes -> Enum.filter(codes, &is_binary/1)
        _other -> model.hears
      end

    # Saved languages are the person's own choice: none is automatic.
    %{
      model
      | speaks: speaks,
        hears: hears,
        auto_hears: if(hears == model.hears, do: model.auto_hears),
        adult_acknowledged?: saved["adult_acknowledged"] == true
    }
  end

  @doc "What `Tui.Config` keeps of the form."
  @spec saved(t()) :: map()
  def saved(model),
    do: %{
      "speaks" => model.speaks,
      "hears" => model.hears,
      "adult_acknowledged" => model.adult_acknowledged?
    }

  ## Server messages

  @doc "Whether this client can carry call audio (sent with `find`)."
  @spec set_audio(t(), boolean()) :: t()
  def set_audio(model, audio?), do: %{model | audio?: audio?}

  @doc "The join reply: initial state and the supported languages."
  @spec joined(t(), map()) :: {t(), [command()]}
  def joined(model, %{"state" => state, "languages" => languages}) do
    first_join? = model.languages == []

    model =
      %{
        model
        | connection: :connected,
          languages: Enum.map(languages, &%{code: &1["code"], name: &1["name"]}),
          # A (re)join is a brand-new participant; don't log it as a transition.
          status: nil
      }
      |> offered_languages_only()

    model =
      if first_join?,
        do: log(model, "connected to the server"),
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

    {model, [{:push, "end_call", %{reason: "audio_unavailable"}}]}
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
      "left" -> {move(model, -1), []}
      "right" -> {move(model, 1), []}
      " " -> {toggle(model), []}
      "enter" -> find(model)
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

  @doc "A language's name, by code (the code itself if the server didn't offer it)."
  @spec language_name(t(), String.t() | nil) :: String.t()
  def language_name(%{languages: []}, _code), do: "…"
  def language_name(_model, nil), do: "…"

  def language_name(model, code) do
    case Enum.find(model.languages, &(&1.code == code)) do
      %{name: name} -> name
      nil -> code
    end
  end

  @doc "The language the hearing row points at, and whether it's checked."
  @spec hears_cursor(t()) :: {String.t(), boolean()} | nil
  def hears_cursor(%{languages: []}), do: nil

  def hears_cursor(model) do
    %{code: code} = Enum.at(model.languages, model.hears_cursor)
    {code, code in model.hears}
  end

  @doc "The language the rando speaks in the current call, when the server says."
  @spec peer_speaks(t()) :: String.t() | nil
  def peer_speaks(%{call: %{"peer_speaks" => code}}) when is_binary(code), do: code
  def peer_speaks(_model), do: nil

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
    # The server's words for the error (the same text the browser shows).
    error = state["error_message"] || state["error"]

    updated = %{
      model
      | status: status,
        webrtc_role: state["webrtc_role"],
        error: error,
        call: state["call"]
    }

    cond do
      error && error != model.error -> log(updated, "error: #{error}")
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
  defp find(%{hears: []} = model),
    do: {log(model, "pick at least one language to hear (space toggles one)"), []}

  defp find(model), do: {model, [{:push, "find", find_payload(model)}]}

  defp find_payload(model) do
    %{
      speaks: model.speaks,
      hears: model.hears,
      adult_acknowledged: model.adult_acknowledged?,
      audio: model.audio?
    }
  end

  defp move(%{languages: []} = model, _step), do: model

  # The speaking language is checked among the hearing ones, replacing the
  # one checked for the previous speaking language (unless the person
  # checked or kept that one themselves), so stepping through the list
  # doesn't check every language on the way.
  defp move(%{focus: :speaks} = model, step) do
    codes = Enum.map(model.languages, & &1.code)
    index = Enum.find_index(codes, &(&1 == model.speaks)) || 0
    speaks = Enum.at(codes, Integer.mod(index + step, length(codes)))
    hears = List.delete(model.hears, model.auto_hears)

    if speaks in hears,
      do: %{model | speaks: speaks, hears: hears, auto_hears: nil},
      else: %{
        model
        | speaks: speaks,
          hears: in_order(model, [speaks | hears]),
          auto_hears: speaks
      }
  end

  defp move(%{focus: :hears} = model, step),
    do: %{model | hears_cursor: Integer.mod(model.hears_cursor + step, length(model.languages))}

  defp move(model, _step), do: model

  defp toggle(%{focus: :hears, languages: [_ | _]} = model) do
    {code, checked?} = hears_cursor(model)

    hears =
      if checked?, do: List.delete(model.hears, code), else: in_order(model, [code | model.hears])

    # Touched by hand: it's the person's choice now, not the automatic one.
    auto_hears = if code == model.auto_hears, do: nil, else: model.auto_hears
    %{model | hears: hears, auto_hears: auto_hears}
  end

  defp toggle(%{focus: :ack} = model),
    do: %{model | adult_acknowledged?: not model.adult_acknowledged?}

  defp toggle(model), do: model

  # Codes in the server's language order (for display), without repeats.
  defp in_order(model, codes),
    do: for(%{code: code} <- model.languages, code in codes, do: code)

  # Saved or default codes the server doesn't offer are dropped.
  defp offered_languages_only(%{languages: languages} = model) do
    codes = Enum.map(languages, & &1.code)
    speaks = if model.speaks in codes, do: model.speaks, else: List.first(codes)
    hears = Enum.filter(model.hears, &(&1 in codes))
    hears = if hears == [] and speaks, do: [speaks], else: hears

    %{
      model
      | speaks: speaks,
        hears: hears,
        hears_cursor: min(model.hears_cursor, length(codes) - 1)
    }
  end

  defp next_focus(:speaks), do: :hears
  defp next_focus(:hears), do: :ack
  defp next_focus(:ack), do: :speaks

  defp prev_focus(:speaks), do: :ack
  defp prev_focus(:hears), do: :speaks
  defp prev_focus(:ack), do: :hears

  defp log(model, line), do: %{model | log: Enum.take([line | model.log], @max_log)}
end
