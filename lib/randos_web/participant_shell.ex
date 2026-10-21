defmodule RandosWeb.ParticipantShell do
  @moduledoc """
  Runs `Randos.Participant` for a transport process (the LiveView or the
  participant channel).

  `run/2` applies an event, executes the server-side effects the core asks for
  (matchmaker and call coordinator calls, made as `self()`), and returns only
  what the transport has to deliver to its client:

    * `{:push_signal, message}` — a WebRTC signal from the peer
    * `{:ice_config, config | nil}` — `RandosWeb.IceServers.call_config/0`
      whenever the participant gets a new call (fresh STUN/TURN servers,
      since credentials are minted per call, and the transport policy),
      `nil` once there is no call

  `client_state/1` is the JSON-safe view of a participant for clients. It
  never includes the match, the peer, or any participant id or pid; the
  call's `media` says how this participant's (`self`) and the peer's
  connection are doing, as each last reported it.
  """

  alias Randos.Calls.Call
  alias Randos.Calls.CallCoordinator
  alias Randos.Calls.Lifecycle
  alias Randos.Matchmaking.Match
  alias Randos.Matchmaking.Matchmaker
  alias Randos.Participant
  alias RandosWeb.IceServers

  @type client_effect :: {:push_signal, map()} | {:ice_config, map() | nil}

  @spec run(Participant.t(), Participant.event()) :: {Participant.t(), [client_effect()]}
  def run(%Participant{} = participant, event) do
    {next, client_effects} = apply_event(participant, event)
    {next, ice_config(participant, next) ++ client_effects}
  end

  @doc "The participant as its client sees it."
  @spec client_state(Participant.t()) :: map()
  def client_state(%Participant{} = participant) do
    %{
      status: participant.status,
      webrtc_role: participant.webrtc_role,
      error: participant.error,
      error_message: RandosWeb.ParticipantErrors.message(participant.error),
      call: client_call(participant.call, participant.id)
    }
  end

  defp client_call(nil, _participant_id), do: nil

  defp client_call(%Call{} = call, participant_id) do
    call
    |> Map.take([
      :id,
      :status,
      :call_deadline_unix_ms,
      :extension_deadline_unix_ms,
      :extension_count,
      :ended_reason
    ])
    |> Map.put(:media, media_view(call, participant_id))
    # So clients can say "continue for another N minutes" without their own
    # copy of the constant.
    |> Map.put(:extension_duration_seconds, Lifecycle.extension_duration_seconds())
  end

  defp media_view(call, participant_id) do
    peer_id =
      case Match.peer(call.match, participant_id) do
        {:ok, peer} -> peer.id
        {:error, _} -> nil
      end

    %{self: Map.get(call.media, participant_id), peer: Map.get(call.media, peer_id)}
  end

  defp apply_event(participant, event) do
    {participant, effects} = Participant.handle(participant, event)

    Enum.reduce(effects, {participant, []}, fn effect, {participant, client_effects} ->
      {participant, more} = run_effect(effect, participant)
      {participant, client_effects ++ more}
    end)
  end

  defp run_effect({:join_queue, attrs}, participant) do
    apply_event(participant, {:join_result, Matchmaker.join(Map.put(attrs, :pid, self()))})
  end

  defp run_effect(:leave_queue, participant) do
    Matchmaker.leave(self())
    {participant, []}
  end

  defp run_effect({:hang_up, call_pid}, participant) do
    CallCoordinator.hang_up(call_pid, participant.id)
    {participant, []}
  end

  defp run_effect({:vote, call_pid, vote}, participant) do
    CallCoordinator.vote_extension(call_pid, participant.id, vote)
    {participant, []}
  end

  defp run_effect({:relay_signal, call_pid, type, payload}, participant) do
    CallCoordinator.relay_signal(call_pid, participant.id, type, payload)
    {participant, []}
  end

  defp run_effect({:push_signal, message}, participant) do
    {participant, [{:push_signal, message}]}
  end

  # Fresh credentials for every new call, so they can never be older than the
  # call that uses them.
  defp ice_config(%{call_pid: same}, %{call_pid: same}), do: []
  defp ice_config(_before, %{call_pid: nil}), do: [{:ice_config, nil}]
  defp ice_config(_before, _after), do: [{:ice_config, IceServers.call_config()}]
end
