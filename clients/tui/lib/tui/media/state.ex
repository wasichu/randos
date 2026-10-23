defmodule Tui.Media.State do
  @moduledoc """
  What the TUI knows about local audio, as pure transitions: each function
  takes the state and an input (a key, a server push, a helper reply or
  event, a timer) and returns `{state, commands}`. `Tui.App` runs the
  commands and never blocks on the helper.

  Two features live here: the mic test (`t`), and call audio. Call health
  is the server's job; this module meets the client obligations in
  `participant_channel.md`, like the browser's `WebRTCClient`: when the
  server says `connecting` and the role and ICE servers are known, start
  the helper's WebRTC session; relay media signals both ways untouched;
  report each change of the helper's connection as a `media_state` signal;
  stop when the server's status leaves the call. If the helper can't carry
  the call (it won't start, or it restarts mid-call), send `end_call` with
  a reason, so only the peer is requeued.

  Commands:

    * `{:request, Tui.Media.Protocol.command()}`: send to `Tui.Media`; its
      reply comes back through `reply/3`
    * `{:push, event, payload}`: send on the participant channel
    * `{:after, ms, message}`: deliver `message` to the app later
  """

  alias Tui.Media.Protocol

  # Media starts at the match (`connecting`), not `in_call`: the server only
  # reports `in_call` once both sides' audio is up.
  @call_statuses Tui.Model.call_statuses()

  @type phase :: :starting | :running | :failed
  @type mic_test :: %{
          phase: phase(),
          stats: map() | nil,
          levels: [float()] | nil,
          error: String.t() | nil
        }
  @type call :: %{
          optional(:levels) => %{you: [float()], peer: [float()]},
          optional(:muted) => boolean(),
          seq: pos_integer(),
          phase: :starting | :active,
          connection: :connecting | :connected | :disconnected,
          stats: map() | nil,
          generation: non_neg_integer()
        }
  @type command ::
          {:request, Protocol.command()}
          | {:push, String.t(), map()}
          | {:after, non_neg_integer(), term()}
  @type t :: %__MODULE__{
          available?: boolean(),
          mic_test: mic_test() | nil,
          endpoints: {String.t(), String.t()},
          status: atom() | nil,
          role: String.t() | nil,
          ice_servers: list() | nil,
          relay_only?: boolean(),
          ice_generation: non_neg_integer(),
          offline_limit_ms: non_neg_integer() | nil,
          offline: pos_integer() | nil,
          drops: non_neg_integer(),
          call: call() | nil,
          calls: non_neg_integer(),
          last_call_error: String.t() | nil,
          devices: map() | nil,
          choice: %{input: String.t() | nil, output: String.t() | nil}
        }

  defstruct available?: false,
            mic_test: nil,
            endpoints: {"device", "device"},
            status: nil,
            role: nil,
            ice_servers: nil,
            relay_only?: false,
            ice_generation: 0,
            offline_limit_ms: nil,
            offline: nil,
            drops: 0,
            call: nil,
            calls: 0,
            last_call_error: nil,
            devices: nil,
            choice: %{input: nil, output: nil}

  @doc """
  `available?`: whether this TUI was started with a media helper at all.
  `endpoints`: `{input, output}` for calls (tests use `{"sine", "null"}`).
  """
  @spec new(boolean(), {String.t(), String.t()}) :: t()
  def new(available?, endpoints \\ {"device", "device"}),
    do: %__MODULE__{available?: available?, endpoints: endpoints}

  ## Mic test

  @doc """
  The mic test key: a silent level meter, on until pressed again. Shown
  (running, or failed), it goes away; hidden, it opens the mic from
  `{input, _output}` (see `Tui.Media.loopback_start/3`). Nothing is played
  back: the output is always `null`, so it never howls without headphones.
  """
  @spec toggle_mic_test(t(), {String.t(), String.t()}) :: {t(), [command()]}
  def toggle_mic_test(%{mic_test: %{phase: phase}} = state, _endpoints)
      when phase in [:starting, :running],
      # The helper handles requests in order, so a stop sent while the start
      # is pending still stops it.
      do: {%{state | mic_test: nil}, [{:request, :loopback_stop}]}

  def toggle_mic_test(%{mic_test: %{phase: :failed}} = state, _endpoints),
    do: {%{state | mic_test: nil}, []}

  def toggle_mic_test(%{call: %{}} = state, _endpoints), do: {state, []}

  def toggle_mic_test(%{available?: false} = state, _endpoints),
    do: {fail_mic_test(state, "no audio helper (cargo build -p randos_media)"), []}

  def toggle_mic_test(state, {input, _output}) do
    {input, output} = with_choice(state, {input, "null"})

    {%{state | mic_test: %{phase: :starting, stats: nil, levels: nil, error: nil}},
     [{:request, {:loopback_start, input, output}}]}
  end

  ## Devices

  @doc """
  Steps the chosen input or output to the next device: the system default
  (`nil`), then each device by name, then back to the default. Takes effect
  for the next mic test or call.
  """
  @spec cycle_device(t(), :input | :output) :: t()
  def cycle_device(%{devices: %{inputs: inputs, outputs: outputs}} = state, which) do
    names = if which == :input, do: inputs, else: outputs
    options = [nil | names]
    current = Enum.find_index(options, &(&1 == state.choice[which])) || 0
    next = Enum.at(options, rem(current + 1, length(options)))
    %{state | choice: Map.put(state.choice, which, next)}
  end

  def cycle_device(state, _which), do: state

  @doc """
  The devices chosen last time (`Tui.Config`), by name. A device that's
  gone by now falls back to the system default when the helper opens it
  (it says so in a notice).
  """
  @spec restore_choice(t(), map()) :: t()
  def restore_choice(state, saved) do
    pick = fn key -> if is_binary(saved[key]), do: saved[key] end
    %{state | choice: %{input: pick.("input"), output: pick.("output")}}
  end

  @doc "What `Tui.Config` keeps of the device choice."
  @spec saved_choice(t()) :: map()
  def saved_choice(state), do: %{"input" => state.choice.input, "output" => state.choice.output}

  # A chosen device replaces "device" (the default); test endpoints like
  # "sine" and "null" are left alone.
  defp with_choice(state, {input, output}),
    do: {choose(input, state.choice.input), choose(output, state.choice.output)}

  defp choose("device", name) when is_binary(name), do: "device:" <> name
  defp choose(endpoint, _name), do: endpoint

  ## Call: inputs from the server

  @doc """
  The server's state push: `status`, `webrtc_role`, and the call map, whose
  `ice_servers` are this call's STUN/TURN servers and whose
  `ice_transport_policy` `"relay"` means the call must go through the TURN
  relay only, so the peer never learns our IP address. When its
  `ice_generation` grows past the one this call last acted on, the server
  is asking for an ICE restart (obligation 10): as offerer, `call_restart`
  (with the latest `ice_servers`); as answerer nothing, the helper
  re-gathers when the restart offer arrives. A resume reply goes through
  here too, so a restart asked for while we were away is acted on.
  """
  @spec server_state(t(), atom() | nil, String.t() | nil, map() | nil) :: {t(), [command()]}
  def server_state(state, status, role, call \\ nil) do
    %{state | status: status, role: role}
    |> struct!(call_fields(call))
    |> follow_status()
  end

  defp call_fields(nil),
    do: %{ice_servers: nil, relay_only?: false, ice_generation: 0, offline_limit_ms: nil}

  defp call_fields(call) do
    %{
      ice_servers: call["ice_servers"],
      relay_only?: call["ice_transport_policy"] == "relay",
      ice_generation: call["ice_generation"] || 0,
      offline_limit_ms: call["offline_limit_seconds"] && call["offline_limit_seconds"] * 1000
    }
  end

  defp follow_status(%{status: status, call: nil} = state) when status in @call_statuses,
    do: maybe_start_call(state)

  defp follow_status(%{status: status} = state) when status in @call_statuses,
    do: maybe_restart(state)

  defp follow_status(%{call: %{}} = state), do: stop_call(state)
  defp follow_status(state), do: {state, []}

  @doc """
  A `signal` push from the peer. One never arrives before our call starts:
  the server forwards only signals for the participant's current call, which
  it learns from the same coordinator message that produces our `connecting`
  push (and messages from one process arrive in order).
  """
  @spec remote_signal(t(), String.t(), map()) :: {t(), [command()]}
  def remote_signal(%{call: %{}} = state, type, payload)
      when type in ["offer", "answer", "ice_candidate"],
      do: {state, [{:request, {:call_signal, type, payload}}]}

  def remote_signal(state, _type, _payload), do: {state, []}

  ## Helper replies, events, timers

  @doc "The helper's reply to a request this module issued."
  @spec reply(t(), Protocol.command(), {:ok, term()} | {:error, String.t()}) ::
          {t(), [command()]}
  def reply(%{mic_test: %{phase: :starting}} = state, {:loopback_start, _, _}, {:ok, _opened}),
    do: {put_mic_test(state, phase: :running), []}

  def reply(%{mic_test: %{phase: :starting}} = state, {:loopback_start, _, _}, {:error, error}),
    do: {fail_mic_test(state, error), []}

  def reply(%{call: %{phase: :starting}} = state, {:call_start, _, _, _, _, _}, {:ok, _opened}),
    do: {put_call(state, phase: :active), []}

  def reply(%{call: %{}} = state, {:call_start, _, _, _, _, _}, {:error, _error}),
    do: give_up(state, "audio_unavailable")

  def reply(state, :devices, {:ok, %{"inputs" => inputs, "outputs" => outputs} = list}) do
    devices = %{
      inputs: inputs,
      outputs: outputs,
      default_input: list["default_input"],
      default_output: list["default_output"]
    }

    {%{state | devices: devices}, []}
  end

  def reply(state, _command, _result), do: {state, []}

  @doc """
  Mutes or unmutes the running call (the helper then sends silence; the
  peer still gets a steady stream). Nothing to do without a call.
  """
  def toggle_mute(%{call: %{} = call} = state) do
    muted = not Map.get(call, :muted, false)
    {put_call(state, muted: muted), [{:request, {:call_mute, muted}}]}
  end

  def toggle_mute(state), do: {state, []}

  @doc "An unsolicited helper event (`{:media, name, payload}` from `Tui.Media`)."
  @spec event(t(), String.t(), map()) :: {t(), [command()]}
  def event(%{mic_test: %{phase: :running}} = state, "loopback_stats", stats),
    do: {put_mic_test(state, stats: stats), []}

  # The meter's bars (20 a second): only drawn.
  def event(%{mic_test: %{phase: :running}} = state, "loopback_levels", %{"you" => you}),
    do: {put_mic_test(state, levels: you), []}

  def event(%{mic_test: %{phase: phase}} = state, "loopback_failed", %{"error" => error})
      when phase in [:starting, :running],
      do: {fail_mic_test(state, error), []}

  def event(%{call: %{}} = state, "call_signal", %{"type" => type, "payload" => payload}),
    do: {state, [{:push, "signal", %{type: type, payload: payload}}]}

  def event(%{call: %{}} = state, "call_state", %{"state" => helper_state} = payload)
      when helper_state in ["connected", "disconnected"],
      do: report_media(state, String.to_existing_atom(helper_state), payload["reason"])

  # The helper's `failed` means its call session stopped (an error it
  # can't come back from), not an ICE failure an ICE restart could fix:
  # end the call with a reason, as when it can't start (obligation 6).
  def event(%{call: %{}} = state, "call_state", %{"state" => "failed"}),
    do: give_up(state, "audio_failed")

  def event(%{call: %{}} = state, "call_stats", stats), do: {put_call(state, stats: stats), []}

  # The audio meters' bars (20 a second): only drawn, never acted on.
  def event(%{call: %{}} = state, "call_levels", %{"you" => you, "peer" => peer}),
    do: {put_call(state, levels: %{you: you, peer: peer}), []}

  # A fresh helper: whatever was running died with the old one.
  def event(state, "ready", _payload) do
    state =
      case state.mic_test do
        %{phase: phase} when phase in [:starting, :running] ->
          fail_mic_test(state, "the audio helper restarted")

        _other ->
          state
      end

    # Ask what devices there are (they may have changed with the restart).
    {state, commands} = if state.call, do: give_up(state, "audio_failed"), else: {state, []}
    {state, commands ++ device_request(state)}
  end

  def event(state, _name, _payload), do: {state, []}

  @doc """
  The helper was already running when the app started (so its "ready" was
  sent before the app could receive it): ask what devices there are.
  """
  @spec helper_started(t()) :: {t(), [command()]}
  def helper_started(%{available?: true} = state), do: {state, device_request(state)}
  def helper_started(state), do: {state, []}

  # Devices matter only when calls use them: with test endpoints (a tone,
  # no output) there's nothing to choose, and listing them would put the
  # machine's device names on screen (`RANDOS_FAKE_AUDIO`'s screenshots).
  defp device_request(%{endpoints: {input, output}}) when "device" in [input, output],
    do: [{:request, :devices}]

  defp device_request(_state), do: []

  ## Internals

  defp maybe_start_call(%{call: nil, available?: true, role: role, ice_servers: ice} = state)
       when is_binary(role) and is_list(ice) do
    {input, output} = with_choice(state, state.endpoints)
    seq = state.calls + 1

    # `generation`: the server's ice_generation this call has acted on.
    call = %{
      seq: seq,
      phase: :starting,
      connection: :connecting,
      stats: nil,
      generation: state.ice_generation
    }

    # The mic test would hold the devices; the call wins.
    {state, stop_test} = stop_mic_test_for_call(state)

    {%{state | call: call, calls: seq, last_call_error: nil},
     stop_test ++ [{:request, {:call_start, role, ice, input, output, state.relay_only?}}]}
  end

  defp maybe_start_call(state), do: {state, []}

  # Obligation 10: only the offerer offers, so restart offers never cross.
  defp maybe_restart(%{call: %{generation: acted}, ice_generation: asked} = state)
       when asked > acted do
    state = put_call(state, generation: asked)

    case state.role do
      "offerer" -> {state, [{:request, {:call_restart, state.ice_servers}}]}
      _answerer -> {state, []}
    end
  end

  defp maybe_restart(state), do: {state, []}

  defp stop_mic_test_for_call(%{mic_test: %{phase: phase}} = state)
       when phase in [:starting, :running],
       do: {%{state | mic_test: nil}, [{:request, :loopback_stop}]}

  defp stop_mic_test_for_call(state), do: {state, []}

  defp stop_call(state),
    do: {%{state | call: nil}, [{:request, :call_stop}]}

  @doc """
  Back in the same call after a dropped connection: the last media state
  again, unchanged (obligation 9: a report sent as the socket dropped may
  never have arrived; the server ignores a repeat). Nothing if no call, or
  nothing reported yet.
  """
  @spec resumed(t()) :: {t(), [command()]}
  def resumed(%{call: %{connection: connection}} = state) when connection != :connecting,
    do: {state, [{:push, "signal", %{type: "media_state", payload: %{state: connection}}}]}

  def resumed(state), do: {state, []}

  @doc """
  The connection to the server dropped (obligation 11): the call's audio
  goes on, but only for the call's offline limit. Past it the server has
  ended the call, so `offline_limit/2` stops the helper's rather than keep
  the mic on for nobody. Each drop is numbered, so an earlier drop's limit
  can't end the call during a later one.
  """
  @spec offline(t()) :: {t(), [command()]}
  def offline(%{call: %{}, offline_limit_ms: limit_ms, drops: drops} = state)
      when is_integer(limit_ms) do
    drop = drops + 1
    {%{state | offline: drop, drops: drop}, [{:after, limit_ms, {:offline_limit, drop}}]}
  end

  def offline(state), do: {state, []}

  @doc "Back in touch with the server: no limit is running any more."
  @spec online(t()) :: {t(), [command()]}
  def online(state), do: {%{state | offline: nil}, []}

  @doc "A drop's limit passed (`offline/1`): stop the call if it's still that drop."
  @spec offline_limit(t(), pos_integer()) :: {t(), [command()]}
  def offline_limit(%{offline: drop, call: %{}} = state, drop),
    do: stop_call(%{state | offline: nil})

  def offline_limit(state, _drop), do: {state, []}

  # Each change of the helper's connection goes to the server, which decides
  # what it means for the call.
  defp report_media(%{call: %{connection: same}} = state, same, _reason), do: {state, []}

  defp report_media(state, connection, reason) do
    payload = if reason, do: %{state: connection, reason: reason}, else: %{state: connection}
    state = put_call(state, connection: connection)
    {state, [{:push, "signal", %{type: "media_state", payload: payload}}]}
  end

  # The helper can't carry this call: end it with a reason (the documented
  # list), so only the peer is requeued and the server tells us why.
  defp give_up(state, reason) do
    {%{state | call: nil, last_call_error: reason},
     [{:request, :call_stop}, {:push, "end_call", %{reason: reason}}]}
  end

  defp fail_mic_test(state, error) do
    mic_test = state.mic_test || %{stats: nil, levels: nil}
    %{state | mic_test: Map.merge(mic_test, %{phase: :failed, error: error})}
  end

  defp put_mic_test(state, changes),
    do: %{state | mic_test: Map.merge(state.mic_test, Map.new(changes))}

  defp put_call(state, changes), do: %{state | call: Map.merge(state.call, Map.new(changes))}
end
