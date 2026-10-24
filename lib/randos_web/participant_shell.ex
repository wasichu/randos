defmodule RandosWeb.ParticipantShell do
  @moduledoc """
  Runs `Randos.Participant` for a transport process (the LiveView or the
  participant channel).

  `run/2` applies an event, executes the server-side effects the core asks for
  (matchmaker and call coordinator calls, made as `self()`), and returns only
  what the transport has to deliver to its client:

    * `{:push_signal, message}` — a WebRTC signal from the peer
    * `{:ice_servers, servers | nil}` — fresh STUN/TURN servers whenever the
      participant gets a new call (credentials are minted per call), `nil`
      once there is no call. The call's transport policy is on the call.

  `client_state/1` is the JSON-safe view of a participant for clients. It
  never includes the match, the peer, or any participant id or pid; the
  call's `media` says how this participant's (`self`) and the peer's
  connection are doing, as each last reported it. An invitation's link is
  built here, from the Endpoint's URL (`PHX_HOST`, the canonical host),
  never the request's.
  """

  use RandosWeb, :verified_routes

  alias Randos.Calls.Call
  alias Randos.Calls.CallCoordinator
  alias Randos.Calls.Lifecycle
  alias Randos.Calls.ResumeTicket
  alias Randos.Matchmaking.Entry
  alias Randos.Matchmaking.Match
  alias Randos.Matchmaking.Matchmaker
  alias Randos.Participant
  alias RandosWeb.IceServers

  @type client_effect ::
          {:push_signal, map()}
          | {:ice_servers, [map()] | nil}
          | {:resume_ticket, String.t()}
          | :detach

  @spec run(Participant.t(), Participant.event()) :: {Participant.t(), [client_effect()]}
  def run(%Participant{} = participant, event) do
    {next, client_effects} = apply_event(participant, event)
    {next, ice_servers(participant, next) ++ client_effects}
  end

  @doc """
  Takes over the participant a resume `ticket` belongs to, for this
  process: their connection dropped mid-call and their client came back
  with the ticket it was given (`ResumeTicket`). Returns the
  participant (same id and topic, back in the call), a fresh ticket for
  the client, and fresh ICE servers for the call (as `run/2` gives when a
  call starts), or `:error` (unknown, used, or the call is over: start
  fresh). The caller subscribes to the participant's topic.
  """
  @spec resume(term()) :: {:ok, Participant.t(), String.t(), [map()]} | :error
  def resume(ticket) do
    with {:ok, call_pid, id} <- ResumeTicket.lookup(ticket),
         {:ok, %{call: call, entry: entry, ticket: fresh}} <-
           CallCoordinator.resume(call_pid, id, ticket, self()) do
      {:ok, Participant.resumed(entry, call), fresh, IceServers.list()}
    else
      _invalid -> :error
    end
  end

  @doc "The participant as its client sees it."
  @spec client_state(Participant.t()) :: map()
  def client_state(%Participant{} = participant) do
    %{
      status: participant.status,
      webrtc_role: participant.webrtc_role,
      error: participant.error,
      error_message: RandosWeb.ParticipantErrors.message(participant.error),
      invitation: client_invitation(participant.invitation),
      notice: participant.notice,
      notice_message: RandosWeb.ParticipantErrors.notice(participant.notice),
      call: client_call(participant.call, participant.id)
    }
  end

  @doc "An invitation as its client sees it: the link to share and when it stops working."
  @spec client_invitation(Participant.invitation() | nil) :: map() | nil
  def client_invitation(nil), do: nil

  def client_invitation(%{token: token, expires_at_unix_ms: expires_at}),
    do: %{url: invitation_url(token), expires_at_unix_ms: expires_at}

  @doc "The link that offers an invitation: the token in the fragment."
  @spec invitation_url(String.t()) :: String.t()
  def invitation_url(token), do: url(~p"/join") <> "#" <> token

  defp client_call(nil, _participant_id), do: nil

  defp client_call(%Call{} = call, participant_id) do
    call
    |> Map.take([
      :id,
      :status,
      :call_deadline_unix_ms,
      :extension_deadline_unix_ms,
      :extension_count,
      :ended_reason,
      :ice_transport_policy,
      # The offerer restarts ICE whenever this grows (obligation 10).
      :ice_generation,
      # Unhealthy and within the recovery budget: say "Reconnecting audio…".
      :recovering
    ])
    |> Map.put(:media, media_view(call, participant_id))
    # The language the rando speaks (with several hearing languages, the
    # client can't know which): a language code, nothing that identifies them.
    |> Map.put(:peer_speaks, peer_speaks(call, participant_id))
    # All they may speak: more than one only for an invitation's joiner,
    # taken to speak whatever the creator hears.
    |> Map.put(:peer_speaks_any, peer_speaks_any(call, participant_id))
    # "invitation": both go idle after it, and there's no "next".
    |> Map.put(:kind, call.match.kind)
    # The rando's connection to the server dropped and the call is waiting
    # for them to come back (within Lifecycle.recovery_budget_seconds/0).
    |> Map.put(:peer_reconnecting, peer_reconnecting?(call, participant_id))
    # This participant's `continue` vote counted (a vote lost in a drop
    # leaves it false, so the client shows the choice again).
    |> Map.put(:agreed_to_continue, agreed_to_continue?(call, participant_id))
    # So clients can say "continue for another N minutes" without their own
    # copy of the constant.
    |> Map.put(:extension_duration_seconds, Lifecycle.extension_duration_seconds())
    # How long to keep the call's media going without the server
    # (obligation 11).
    |> Map.put(:offline_limit_seconds, Lifecycle.offline_limit_seconds())
  end

  @doc "Whether the participant's vote to continue the call has counted."
  @spec agreed_to_continue?(Call.t(), String.t()) :: boolean()
  def agreed_to_continue?(%Call{continuing: continuing}, participant_id),
    do: participant_id in continuing

  @doc "Whether the participant's rando dropped out of the call and may come back."
  @spec peer_reconnecting?(Call.t(), String.t()) :: boolean()
  def peer_reconnecting?(call, participant_id) do
    case Match.peer(call.match, participant_id) do
      {:ok, peer} -> peer.id in call.away
      {:error, _} -> false
    end
  end

  defp media_view(call, participant_id) do
    peer_id =
      case Match.peer(call.match, participant_id) do
        {:ok, peer} -> peer.id
        {:error, _} -> nil
      end

    %{self: Map.get(call.media, participant_id), peer: Map.get(call.media, peer_id)}
  end

  @doc "The language the participant's rando speaks in this call (`nil` if not in it)."
  @spec peer_speaks(Call.t(), String.t()) :: String.t() | nil
  def peer_speaks(%Call{match: match}, participant_id) do
    case Match.peer(match, participant_id) do
      {:ok, peer} -> peer.speaks_language
      {:error, _} -> nil
    end
  end

  @doc "Every language the participant's rando may speak in this call (`[]` if not in it)."
  @spec peer_speaks_any(Call.t(), String.t()) :: [String.t()]
  def peer_speaks_any(%Call{match: match}, participant_id) do
    case Match.peer(match, participant_id) do
      {:ok, peer} -> Entry.speaks_any(peer)
      {:error, _} -> []
    end
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

  defp run_effect({:invite, attrs}, participant) do
    apply_event(participant, {:invite_result, Matchmaker.invite(Map.put(attrs, :pid, self()))})
  end

  defp run_effect(:cancel_invitation, participant) do
    Matchmaker.cancel_invitation(self())
    {participant, []}
  end

  defp run_effect({:accept_invitation, token, attrs}, participant) do
    result = Matchmaker.accept(token, Map.put(attrs, :pid, self()))
    apply_event(participant, {:accept_result, result})
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

  defp run_effect({:push_resume_ticket, ticket}, participant),
    do: {participant, [{:resume_ticket, ticket}]}

  defp run_effect(:detach, participant), do: {participant, [:detach]}

  # Fresh credentials for every new call, so they can never be older than the
  # call that uses them.
  defp ice_servers(%{call_pid: same}, %{call_pid: same}), do: []
  defp ice_servers(_before, %{call_pid: nil}), do: [{:ice_servers, nil}]
  defp ice_servers(_before, _after), do: [{:ice_servers, IceServers.list()}]
end
