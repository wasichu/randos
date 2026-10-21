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

  @mic_test_ms 5_000
  # Media starts at the match (`connecting`), not `in_call`: the server only
  # reports `in_call` once both sides' audio is up.
  @call_statuses [:connecting, :in_call, :extension_pending]

  @type phase :: :starting | :running | :done | :failed
  @type mic_test :: %{phase: phase(), stats: map() | nil, error: String.t() | nil}
  @type call :: %{
          optional(:levels) => %{you: [float()], peer: [float()]},
          optional(:muted) => boolean(),
          seq: pos_integer(),
          phase: :starting | :active,
          connection: :connecting | :connected | :disconnected | :failed,
          stats: map() | nil
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

  @doc "The user asked for a mic test, through `{input, output}` (see `Tui.Media.loopback_start/3`)."
  @spec start_mic_test(t(), {String.t(), String.t()}) :: {t(), [command()]}
  def start_mic_test(%{mic_test: %{phase: phase}} = state, _endpoints)
      when phase in [:starting, :running],
      do: {state, []}

  def start_mic_test(%{call: %{}} = state, _endpoints), do: {state, []}

  def start_mic_test(%{available?: false} = state, _endpoints),
    do: {fail_mic_test(state, "no audio helper (cargo build -p randos_media)"), []}

  def start_mic_test(state, endpoints) do
    {input, output} = with_choice(state, endpoints)

    {%{state | mic_test: %{phase: :starting, stats: nil, error: nil}},
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

  # A chosen device replaces "device" (the default); test endpoints like
  # "sine" and "null" are left alone.
  defp with_choice(state, {input, output}),
    do: {choose(input, state.choice.input), choose(output, state.choice.output)}

  defp choose("device", name) when is_binary(name), do: "device:" <> name
  defp choose(endpoint, _name), do: endpoint

  @doc "The mic test's time is up."
  @spec mic_test_done(t()) :: {t(), [command()]}
  def mic_test_done(%{mic_test: %{phase: :running}} = state),
    do: {put_mic_test(state, phase: :done), [{:request, :loopback_stop}]}

  def mic_test_done(state), do: {state, []}

  ## Call: inputs from the server

  @doc """
  The server's state push: `status`, `webrtc_role`, and the call map, whose
  `ice_servers` are this call's STUN/TURN servers and whose
  `ice_transport_policy` `"relay"` means the call must go through the TURN
  relay only, so the peer never learns our IP address.
  """
  @spec server_state(t(), atom() | nil, String.t() | nil, map() | nil) :: {t(), [command()]}
  def server_state(state, status, role, call \\ nil) do
    state = %{
      state
      | status: status,
        role: role,
        ice_servers: call && call["ice_servers"],
        relay_only?: call != nil and call["ice_transport_policy"] == "relay"
    }

    cond do
      status in @call_statuses -> maybe_start_call(state)
      state.call != nil -> stop_call(state)
      true -> {state, []}
    end
  end

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
  def reply(%{mic_test: %{phase: :starting}} = state, {:loopback_start, _, _}, {:ok, _opened}) do
    {put_mic_test(state, phase: :running), [{:after, @mic_test_ms, :mic_test_done}]}
  end

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

  def event(%{mic_test: %{phase: phase}} = state, "loopback_failed", %{"error" => error})
      when phase in [:starting, :running],
      do: {fail_mic_test(state, error), []}

  def event(%{call: %{}} = state, "call_signal", %{"type" => type, "payload" => payload}),
    do: {state, [{:push, "signal", %{type: type, payload: payload}}]}

  def event(%{call: %{}} = state, "call_state", %{"state" => helper_state} = payload)
      when helper_state in ["connected", "disconnected", "failed"],
      do: report_media(state, String.to_existing_atom(helper_state), payload["reason"])

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

    call = %{seq: seq, phase: :starting, connection: :connecting, stats: nil}

    # The mic test would hold the devices; the call wins.
    {state, stop_test} = stop_mic_test_for_call(state)

    {%{state | call: call, calls: seq, last_call_error: nil},
     stop_test ++ [{:request, {:call_start, role, ice, input, output, state.relay_only?}}]}
  end

  defp maybe_start_call(state), do: {state, []}

  defp stop_mic_test_for_call(%{mic_test: %{phase: phase}} = state)
       when phase in [:starting, :running],
       do: {put_mic_test(state, phase: :done), [{:request, :loopback_stop}]}

  defp stop_mic_test_for_call(state), do: {state, []}

  defp stop_call(state),
    do: {%{state | call: nil}, [{:request, :call_stop}]}

  # Each change of the helper's connection goes to the server, which decides
  # what it means for the call. A failed session has stopped on its own.
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
    mic_test = state.mic_test || %{stats: nil}
    %{state | mic_test: Map.merge(mic_test, %{phase: :failed, error: error})}
  end

  defp put_mic_test(state, changes),
    do: %{state | mic_test: Map.merge(state.mic_test, Map.new(changes))}

  defp put_call(state, changes), do: %{state | call: Map.merge(state.call, Map.new(changes))}
end
