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

  `status_page` is the server status screen (`s` on the idle screen): `nil`
  when closed; when open, the latest `status` reply (`snapshot`, the same
  data as the website's /status page), or `unavailable?` for a server that
  doesn't know the request, and when it was last asked for (refreshed every
  30 s while open, see `refresh_status/1`).

  Invitations (the protocol doc's "Invitations"): `v` on the idle screen
  sends `invite`, and the server's `invitation` (the link to share) is
  shown while `inviting`; `j` opens `join_prompt`, where a link is typed
  or pasted (a paste on the idle screen opens it too), and Enter sends
  `accept_invitation` with the part after `#`. An invitation call
  (`call.kind`) has no `next`.
  """

  use Gettext, backend: Tui.Gettext

  @max_log 30
  @status_refresh_ms 30_000

  @type status :: :connecting | :idle | :looking | :inviting | :in_call | :extension_pending
  @type command :: {:push, String.t(), map()}

  @typedoc """
  `speaks` is a language code; `hears` the codes the person is happy to
  hear. The speaking language starts checked (without saved settings);
  after that the hearing choices are the person's alone, whatever they
  speak, as on the website. `hears_cursor` is the language the hearing row
  points at (space toggles it).
  """
  @type t :: %__MODULE__{
          connection: :connecting | :connected,
          languages: [%{code: String.t(), name: String.t()}],
          speaks: String.t(),
          hears: [String.t()],
          hears_cursor: non_neg_integer(),
          adult_acknowledged?: boolean(),
          audio?: boolean(),
          focus: :speaks | :hears | :ack,
          status: status() | nil,
          webrtc_role: String.t() | nil,
          error: String.t() | nil,
          call: map() | nil,
          now_ms: integer(),
          log: [String.t()],
          status_page: status_page() | nil,
          language: String.t(),
          invitation: map() | nil,
          join_prompt: String.t() | nil
        }

  # `info?`: the "About these numbers" pop-up is open (i).
  @type status_page :: %{
          snapshot: map() | nil,
          unavailable?: boolean(),
          asked_ms: integer(),
          info?: boolean()
        }

  defstruct connection: :connecting,
            languages: [],
            speaks: "en",
            hears: ["en"],
            hears_cursor: 0,
            adult_acknowledged?: false,
            audio?: false,
            focus: :speaks,
            status: nil,
            webrtc_role: nil,
            error: nil,
            call: nil,
            now_ms: 0,
            log: [],
            status_page: nil,
            language: "en",
            invitation: nil,
            join_prompt: nil

  @statuses %{
    "idle" => :idle,
    "looking" => :looking,
    "inviting" => :inviting,
    "connecting" => :connecting,
    "in_call" => :in_call,
    "extension_pending" => :extension_pending
  }

  @spec new(integer()) :: t()
  def new(now_ms \\ 0), do: %__MODULE__{now_ms: now_ms}

  @doc """
  The statuses that carry a call, from the match (`connecting`: media starts
  then) to its end: guards take it as `@call_statuses Tui.Model.call_statuses()`.
  """
  @spec call_statuses() :: [status()]
  def call_statuses, do: [:connecting, :in_call, :extension_pending]

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
        adult_acknowledged?: saved["adult_acknowledged"] == true
    }
  end

  @doc "What `Tui.Config` keeps of the form, and the interface language."
  @spec saved(t()) :: map()
  def saved(model),
    do: %{
      "speaks" => model.speaks,
      "hears" => model.hears,
      "adult_acknowledged" => model.adult_acknowledged?,
      "language" => model.language
    }

  ## Server messages

  @doc "Whether this client can carry call audio (sent with `find`)."
  @spec set_audio(t(), boolean()) :: t()
  def set_audio(model, audio?), do: %{model | audio?: audio?}

  @doc """
  The join reply: initial state and the supported languages. After a
  dropped connection, `"resumed" => true` means we're the same participant,
  back in our call.
  """
  @spec joined(t(), map()) :: {t(), [command()]}
  def joined(model, %{"state" => state, "languages" => languages} = reply) do
    first_join? = model.languages == []
    resumed? = reply["resumed"] == true

    model =
      %{
        model
        | connection: :connected,
          languages: Enum.map(languages, &%{code: &1["code"], name: &1["name"]}),
          # A (re)join is a brand-new participant, unless it resumed;
          # don't log it as a transition.
          status: if(resumed?, do: model.status)
      }
      |> offered_languages_only()

    model =
      cond do
        first_join? -> log(model, gettext("connected to the server"))
        resumed? -> log(model, gettext("reconnected; back in the call"))
        true -> log(model, gettext("reconnected as a new participant"))
      end

    {put_state(model, state), []}
  end

  @spec disconnected(t()) :: {t(), [command()]}
  def disconnected(model) do
    {log(%{model | connection: :connecting}, gettext("disconnected; reconnecting")), []}
  end

  @doc "A server push on the participant channel."
  @spec push(t(), String.t(), map()) :: {t(), [command()]}
  def push(model, "state", state), do: {put_state(model, state), []}

  def push(%{audio?: false} = model, "signal", %{"type" => "offer"}) do
    # end_call (not connection_failed): it ends the call with us stopping, so
    # only the peer is requeued. Any other ending requeues both of us, and
    # we'd rematch and refuse again in a loop.
    model =
      log(
        model,
        gettext(
          "peer offered audio; this client has none, so the call ended (Enter to look again)"
        )
      )

    {model, [{:push, "end_call", %{reason: "audio_unavailable"}}]}
  end

  def push(model, "signal", _signal), do: {model, []}
  def push(model, _event, _payload), do: {model, []}

  @doc """
  A reply to one of our pushes: a `status` reply fills the status screen
  (if it's still open); otherwise only errors are worth showing.
  """
  @spec reply(t(), String.t(), {:ok, map()} | {:error, map()}) :: {t(), [command()]}
  def reply(%{status_page: %{} = page} = model, "status", {:ok, %{"relay" => _} = snapshot}),
    do: {%{model | status_page: %{page | snapshot: snapshot, unavailable?: false}}, []}

  # A server from before the `status` request: say so on the screen.
  def reply(%{status_page: %{} = page} = model, "status", {:error, _reply}),
    do: {%{model | status_page: %{page | unavailable?: true}}, []}

  def reply(model, "status", _reply), do: {model, []}

  def reply(model, event, {:error, %{"reason" => reason}}),
    do: {log(model, gettext("%{request} refused: %{reason}", request: event, reason: reason)), []}

  def reply(model, _event, _reply), do: {model, []}

  @spec tick(t(), integer()) :: t()
  def tick(model, now_ms), do: %{model | now_ms: now_ms}

  @doc "While the status screen is open, asks again once its data is 30 s old."
  @spec refresh_status(t()) :: {t(), [command()]}
  def refresh_status(%{status_page: %{asked_ms: asked}} = model)
      when model.now_ms - asked >= @status_refresh_ms,
      do: ask_status(model)

  def refresh_status(model), do: {model, []}

  defp ask_status(model) do
    page = model.status_page || %{snapshot: nil, unavailable?: false, info?: false}
    {%{model | status_page: Map.put(page, :asked_ms, model.now_ms)}, [{:push, "status", %{}}]}
  end

  ## Keys

  @doc "A key press (ex_ratatui key code string) in the current status."
  @spec key(t(), String.t()) :: {t(), [command()]}
  def key(%{connection: :connecting} = model, _key), do: {model, []}

  # The join prompt takes every key: a link is typed (or pasted, `paste/2`).
  def key(%{join_prompt: text} = model, key) when is_binary(text) do
    case key do
      "esc" ->
        {%{model | join_prompt: nil}, []}

      "enter" ->
        accept(model)

      "backspace" ->
        {%{model | join_prompt: String.slice(text, 0..-2//1)}, []}

      k ->
        if String.length(k) == 1, do: {%{model | join_prompt: text <> k}, []}, else: {model, []}
    end
  end

  # The status screen: i opens or closes "About these numbers" (esc closes it
  # first); s or esc goes back, r asks again now.
  def key(%{status: :idle, status_page: %{info?: true} = page} = model, k) when k in ["i", "esc"],
    do: {%{model | status_page: %{page | info?: false}}, []}

  def key(%{status: :idle, status_page: %{} = page} = model, "i"),
    do: {%{model | status_page: Map.put(page, :info?, true)}, []}

  def key(%{status: :idle, status_page: %{}} = model, k) when k in ["s", "esc"],
    do: {%{model | status_page: nil}, []}

  def key(%{status: :idle, status_page: %{}} = model, "r"), do: ask_status(model)
  def key(%{status: :idle, status_page: %{}} = model, _key), do: {model, []}

  def key(%{status: :idle} = model, "s"), do: ask_status(model)

  def key(%{status: :idle} = model, "l"),
    do: {%{model | language: Tui.Language.next(model.language)}, []}

  def key(%{status: :idle} = model, "v"), do: invite(model)
  def key(%{status: :idle} = model, "j"), do: {%{model | join_prompt: ""}, []}

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

  def key(%{status: :inviting} = model, k) when k in ["c", "esc"],
    do: {model, [{:push, "cancel_invitation", %{}}]}

  # No next in an invitation call (the server ignores it anyway).
  def key(%{status: s, call: %{"kind" => "invitation"}} = model, "n")
      when s in [:connecting, :in_call],
      do: {model, []}

  def key(%{status: s} = model, "e") when s in [:connecting, :in_call],
    do: {model, [{:push, "end_call", %{}}]}

  def key(%{status: s} = model, "n") when s in [:connecting, :in_call],
    do: {model, [{:push, "next", %{}}]}

  def key(%{status: :extension_pending} = model, "y"),
    do: {model, [{:push, "vote", %{vote: "continue"}}]}

  def key(%{status: :extension_pending} = model, k) when k in ["n", "e"],
    do: {model, [{:push, "vote", %{vote: "end"}}]}

  def key(model, _key), do: {model, []}

  @doc """
  Pasted text (a bracketed paste, one event): into the join prompt, which
  a paste on the idle screen opens.
  """
  @spec paste(t(), String.t()) :: {t(), [command()]}
  def paste(%{join_prompt: text} = model, pasted) when is_binary(text),
    do: {%{model | join_prompt: text <> one_line(pasted)}, []}

  def paste(%{connection: :connected, status: :idle, status_page: nil} = model, pasted),
    do: {%{model | join_prompt: one_line(pasted)}, []}

  def paste(model, _pasted), do: {model, []}

  defp one_line(text), do: text |> String.replace(~r/[\r\n\t]/, "") |> String.trim()

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

  @doc """
  Every language the rando may speak: more than one only when they joined
  your invitation (taken to speak whatever you hear).
  """
  @spec peer_speaks_any(t()) :: [String.t()]
  def peer_speaks_any(%{call: %{"peer_speaks_any" => [_ | _] = codes}}), do: codes
  def peer_speaks_any(model), do: List.wrap(peer_speaks(model))

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
        call: state["call"],
        invitation: state["invitation"]
    }

    cond do
      error && error != model.error -> log(updated, gettext("error: %{message}", message: error))
      status != model.status and model.status != nil -> log(updated, status_line(status))
      true -> updated
    end
  end

  # The log's line when the status changes.
  defp status_line(:idle), do: pgettext("log", "idle")
  defp status_line(:looking), do: pgettext("log", "looking for a rando")
  defp status_line(:inviting), do: pgettext("log", "invitation link ready to share")
  defp status_line(:connecting), do: pgettext("log", "matched; connecting")
  defp status_line(:in_call), do: pgettext("log", "in call")
  defp status_line(:extension_pending), do: pgettext("log", "time is up: continue? (y/n)")

  # Without audio the server pairs us only with other text-only clients,
  # never with a browser user who would sit through a silent call.
  defp find(%{hears: []} = model),
    do: {log(model, gettext("pick at least one language to hear (space toggles one)")), []}

  defp find(model), do: {model, [{:push, "find", find_payload(model)}]}

  # The same choices as find: what you'll speak, what you'd hear from them.
  defp invite(%{hears: []} = model), do: find(model)
  defp invite(model), do: {model, [{:push, "invite", find_payload(model)}]}

  # The token is the link's part after "#" (or the whole thing, pasted bare).
  defp accept(%{join_prompt: text} = model) do
    token = text |> String.split("#") |> List.last() |> String.trim()

    cond do
      token == "" ->
        {log(model, gettext("paste the whole link you were sent")), []}

      not model.adult_acknowledged? ->
        gettext_comment("The joiner hasn't ticked the 18+ box on the form yet.")
        {log(%{model | join_prompt: nil}, gettext("tick the 18+ box on the form first")), []}

      true ->
        payload = %{
          token: token,
          adult_acknowledged: true,
          audio: model.audio?,
          ice_restart: model.audio?
        }

        {%{model | join_prompt: nil}, [{:push, "accept_invitation", payload}]}
    end
  end

  defp find_payload(model) do
    %{
      speaks: model.speaks,
      hears: model.hears,
      adult_acknowledged: model.adult_acknowledged?,
      audio: model.audio?,
      # Our helper restarts ICE when the server asks (obligation 10).
      ice_restart: model.audio?
    }
  end

  defp move(%{languages: []} = model, _step), do: model

  # Changing the speaking language leaves the hearing choices alone.
  defp move(%{focus: :speaks} = model, step) do
    codes = Enum.map(model.languages, & &1.code)
    index = Enum.find_index(codes, &(&1 == model.speaks)) || 0
    %{model | speaks: Enum.at(codes, Integer.mod(index + step, length(codes)))}
  end

  defp move(%{focus: :hears} = model, step),
    do: %{model | hears_cursor: Integer.mod(model.hears_cursor + step, length(model.languages))}

  defp move(model, _step), do: model

  defp toggle(%{focus: :hears, languages: [_ | _]} = model) do
    {code, checked?} = hears_cursor(model)

    hears =
      if checked?, do: List.delete(model.hears, code), else: in_order(model, [code | model.hears])

    %{model | hears: hears}
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
