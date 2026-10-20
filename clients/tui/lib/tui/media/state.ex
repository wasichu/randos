defmodule Tui.Media.State do
  @moduledoc """
  What the TUI knows about local audio, as pure transitions: each function
  takes the state and an input (a key, a server push, a helper reply or
  event, a timer) and returns `{state, commands}`. `Tui.App` runs the
  commands and never blocks on the helper.

  Two features live here: the mic test (`t`), and call audio. A call
  mirrors the browser's `WebRTCClient`: when the server says `in_call` and
  the role and ICE servers are known, start the helper's WebRTC session;
  relay signals both ways untouched; report `connection_established` once,
  and `connection_failed` on failure or after a 5 s `disconnected` grace;
  stop when the call ends. If the helper can't carry the call (it won't
  start, or it restarts mid-call), send `end_call`, the 4.2 fallback, so
  only the peer is requeued.

  Commands:

    * `{:request, Tui.Media.Protocol.command()}`: send to `Tui.Media`; its
      reply comes back through `reply/3`
    * `{:push, event, payload}`: send on the participant channel
    * `{:after, ms, message}`: deliver `message` to the app later
  """

  alias Tui.Media.Protocol

  @mic_test_ms 5_000
  # Same grace as the browser (`DISCONNECTED_GRACE_MS`).
  @disconnected_grace_ms 5_000
  @in_call [:in_call, :extension_pending]

  @type phase :: :starting | :running | :done | :failed
  @type mic_test :: %{phase: phase(), stats: map() | nil, error: String.t() | nil}
  @type call :: %{
          seq: pos_integer(),
          phase: :starting | :active,
          connection: :connecting | :connected | :disconnected,
          established_sent?: boolean(),
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
          call: call() | nil,
          calls: non_neg_integer(),
          pending_signals: [{String.t(), map()}],
          last_call_error: String.t() | nil
        }

  defstruct available?: false,
            mic_test: nil,
            endpoints: {"device", "device"},
            status: nil,
            role: nil,
            ice_servers: nil,
            call: nil,
            calls: 0,
            pending_signals: [],
            last_call_error: nil

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

  def start_mic_test(state, {input, output}) do
    {%{state | mic_test: %{phase: :starting, stats: nil, error: nil}},
     [{:request, {:loopback_start, input, output}}]}
  end

  @doc "The mic test's time is up."
  @spec mic_test_done(t()) :: {t(), [command()]}
  def mic_test_done(%{mic_test: %{phase: :running}} = state),
    do: {put_mic_test(state, phase: :done), [{:request, :loopback_stop}]}

  def mic_test_done(state), do: {state, []}

  ## Call: inputs from the server

  @doc "The server's state push: `status` and `webrtc_role` (as strings or atoms)."
  @spec server_state(t(), atom() | nil, String.t() | nil) :: {t(), [command()]}
  def server_state(state, status, role) do
    state = %{state | status: status, role: role}

    cond do
      status in @in_call -> maybe_start_call(state)
      state.call != nil -> stop_call(state)
      true -> {%{state | pending_signals: []}, []}
    end
  end

  @doc "The server's `ice_servers` push (`nil` once there's no call)."
  @spec ice_servers(t(), list() | nil) :: {t(), [command()]}
  def ice_servers(state, servers) do
    state = %{state | ice_servers: servers}
    if state.status in @in_call, do: maybe_start_call(state), else: {state, []}
  end

  @doc "A `signal` push from the peer."
  @spec remote_signal(t(), String.t(), map()) :: {t(), [command()]}
  def remote_signal(%{call: nil} = state, type, payload) when type in ["offer", "ice_candidate"],
    do: {%{state | pending_signals: [{type, payload} | state.pending_signals]}, []}

  def remote_signal(%{call: %{}} = state, type, payload)
      when type in ["offer", "answer", "ice_candidate"],
      do: {state, [{:request, {:call_signal, type, payload}}]}

  def remote_signal(%{call: %{}} = state, type, _payload)
      when type in ["connection_failed", "peer_disconnected"],
      do: stop_call(state)

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

  def reply(%{call: %{phase: :starting}} = state, {:call_start, _, _, _, _}, {:ok, _opened}),
    do: {put_call(state, phase: :active), []}

  def reply(%{call: %{}} = state, {:call_start, _, _, _, _}, {:error, error}),
    do: give_up(state, error)

  def reply(state, _command, _result), do: {state, []}

  @doc "An unsolicited helper event (`{:media, name, payload}` from `Tui.Media`)."
  @spec event(t(), String.t(), map()) :: {t(), [command()]}
  def event(%{mic_test: %{phase: :running}} = state, "loopback_stats", stats),
    do: {put_mic_test(state, stats: stats), []}

  def event(%{mic_test: %{phase: phase}} = state, "loopback_failed", %{"error" => error})
      when phase in [:starting, :running],
      do: {fail_mic_test(state, error), []}

  def event(%{call: %{}} = state, "call_signal", %{"type" => type, "payload" => payload}),
    do: {state, [{:push, "signal", %{type: type, payload: payload}}]}

  def event(%{call: %{}} = state, "call_state", %{"state" => "connected"}) do
    commands =
      if state.call.established_sent?,
        do: [],
        else: [
          {:push, "signal", %{type: "connection_established", payload: %{helper: "connected"}}}
        ]

    {put_call(state, connection: :connected, established_sent?: true), commands}
  end

  def event(%{call: %{}} = state, "call_state", %{"state" => "disconnected"}) do
    {put_call(state, connection: :disconnected),
     [{:after, @disconnected_grace_ms, {:media_call_grace, state.call.seq}}]}
  end

  def event(%{call: %{}} = state, "call_state", %{"state" => "failed"} = payload),
    do: fail_call(state, %{helper: "failed", reason: payload["reason"]})

  def event(%{call: %{}} = state, "call_stats", stats), do: {put_call(state, stats: stats), []}

  # A fresh helper: whatever was running died with the old one.
  def event(state, "ready", _payload) do
    state =
      case state.mic_test do
        %{phase: phase} when phase in [:starting, :running] ->
          fail_mic_test(state, "the audio helper restarted")

        _other ->
          state
      end

    if state.call, do: give_up(state, "the audio helper restarted"), else: {state, []}
  end

  def event(state, _name, _payload), do: {state, []}

  @doc "The `disconnected` grace timer for call `seq` fired."
  @spec call_grace(t(), pos_integer()) :: {t(), [command()]}
  def call_grace(%{call: %{seq: seq, connection: :disconnected}} = state, seq),
    do: fail_call(state, %{helper: "disconnected", reason: "disconnected_timeout"})

  def call_grace(state, _seq), do: {state, []}

  ## Internals

  defp maybe_start_call(%{call: nil, available?: true, role: role, ice_servers: ice} = state)
       when is_binary(role) and is_list(ice) do
    {input, output} = state.endpoints
    seq = state.calls + 1

    call = %{
      seq: seq,
      phase: :starting,
      connection: :connecting,
      established_sent?: false,
      stats: nil
    }

    # The mic test would hold the devices; the call wins.
    {state, stop_test} = stop_mic_test_for_call(state)

    # The helper takes requests in order, so signals that arrived before
    # the call can follow call_start straight away.
    pending =
      state.pending_signals
      |> Enum.reverse()
      |> Enum.map(fn {type, payload} -> {:request, {:call_signal, type, payload}} end)

    {%{state | call: call, calls: seq, pending_signals: [], last_call_error: nil},
     stop_test ++ [{:request, {:call_start, role, ice, input, output}}] ++ pending}
  end

  defp maybe_start_call(state), do: {state, []}

  defp stop_mic_test_for_call(%{mic_test: %{phase: phase}} = state)
       when phase in [:starting, :running],
       do: {put_mic_test(state, phase: :done), [{:request, :loopback_stop}]}

  defp stop_mic_test_for_call(state), do: {state, []}

  defp stop_call(state),
    do: {%{state | call: nil, pending_signals: []}, [{:request, :call_stop}]}

  defp fail_call(state, payload) do
    {state, stop} = stop_call(state)

    {%{state | last_call_error: payload.reason || "call failed"},
     [{:push, "signal", %{type: "connection_failed", payload: payload}} | stop]}
  end

  # The helper can't carry this call: end it so only the peer is requeued.
  defp give_up(state, reason) do
    {%{state | call: nil, pending_signals: [], last_call_error: reason},
     [{:request, :call_stop}, {:push, "end_call", %{}}]}
  end

  defp fail_mic_test(state, error) do
    mic_test = state.mic_test || %{stats: nil}
    %{state | mic_test: Map.merge(mic_test, %{phase: :failed, error: error})}
  end

  defp put_mic_test(state, changes),
    do: %{state | mic_test: Map.merge(state.mic_test, Map.new(changes))}

  defp put_call(state, changes), do: %{state | call: Map.merge(state.call, Map.new(changes))}
end
