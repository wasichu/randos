defmodule Randos.Participant do
  @moduledoc """
  The UI-agnostic core of one person using randos: their flow from choosing
  languages, through the queue, into calls and back.

  Pure and process-free. A shell (`RandosWeb.ParticipantShell`, under the
  LiveView and the participant channel) feeds it events and runs the effects it returns:

      {participant, effects} = Participant.handle(participant, event)

  ## Statuses

      :idle ──find──▶ (join) ──▶ :looking ──matched──▶ :connecting ──▶ :in_call ◀─┐
        ▲                          │                                    │         │
        └──────── cancel_search ───┘                                    ▼         │
        ▲                                                       :extension_pending┘
        └── call ended + stop_after_call? ── (otherwise back to :looking) ◀──┘

  An invitation (`{:invite, prefs}`) waits as `:inviting` instead of
  `:looking`, with the link's token in `invitation`, until someone accepts
  it (then it adopts its call as `:looking` does), it's cancelled
  (`:cancel_invitation`) or it expires (`:invitation_expired`). The other
  person joins with `{:accept_invitation, token, prefs}`. After an
  invitation call (`call.match.kind == :invitation`) both go `:idle`, and
  `:next` does nothing in one; whoever didn't end it gets the `notice`
  `:call_ended`, so the form coming back isn't a surprise (the next find,
  invite or accept clears it).

  ## Which calls are mine

  A `{:call_updated, call}` is only considered when the participant is in
  `call.match`. Then:

    * it updates the current call when `call.pid` is the current `call_pid`;
    * it is adopted when the participant is `:looking` or `:inviting` (the
      matchmaker paired us while we waited);
    * it is declined (`{:hang_up, pid}`) when the participant is `:idle`
      (they cancelled the search just as they were matched);
    * anything else is stale and ignored.

  Signaling is forwarded to the client only for the current call.
  """

  alias Randos.Calls.Call
  alias Randos.Matchmaking.Match
  alias Randos.Signaling

  @type status :: :idle | :looking | :inviting | :connecting | :in_call | :extension_pending

  @typedoc """
  What the person asked for: the language they'll speak, and the languages
  they're happy to hear (`hears`, at least one). `audio?` is whether their
  client can carry call audio (WebRTC); only clients that agree on it are
  matched, so nobody sits through a silent call with a text-only client.
  `ice_restart?` is whether it can restart ICE when the server asks
  (obligation 10); optional, `false` for clients from before.
  """
  @type preferences :: %{
          required(:speaks) => String.t(),
          required(:hears) => [String.t()],
          required(:adult_acknowledged?) => boolean(),
          required(:audio?) => boolean(),
          optional(:ice_restart?) => boolean()
        }

  @typedoc """
  Shown to the person. The `end_call_reason`s say why their own client
  ended a call it couldn't carry (no mic, no audio); they go back to idle,
  and only the peer is requeued.
  """
  @type error ::
          :adult_terms_required
          | :unsupported_language
          | :call_start_failed
          | :invitation_invalid
          | :invitation_expired
          | :audio_mismatch
          | end_call_reason()

  @type end_call_reason ::
          :microphone_denied | :microphone_not_found | :audio_unavailable | :audio_failed

  @type join_result :: Randos.Matchmaking.Matchmaker.join_result()

  @typedoc "An invitation's link token and when it stops working."
  @type invitation :: %{token: String.t(), expires_at_unix_ms: integer()}

  @type event ::
          {:update_preferences, preferences()}
          | {:find, preferences()}
          | :cancel_search
          | {:invite, preferences()}
          | :cancel_invitation
          | :invitation_expired
          | {:accept_invitation, String.t(), map()}
          | {:invite_result, Randos.Matchmaking.Matchmaker.invite_result()}
          | {:accept_result, Randos.Matchmaking.Matchmaker.accept_result()}
          | :end_call
          | {:end_call, end_call_reason()}
          | :next
          | {:vote, :continue | :end}
          | {:client_signal, String.t(), map()}
          | {:join_result, join_result()}
          | {:call_updated, Call.t()}
          | {:signaling, Signaling.message()}
          | {:resume_ticket, pid(), String.t()}
          | {:resumed_elsewhere, pid()}

  @typedoc """
  Work for the shell. `{:join_queue, attrs}`'s result must be fed back as
  `{:join_result, result}`, `{:invite, attrs}`'s as `{:invite_result, _}`
  and `{:accept_invitation, token, attrs}`'s as `{:accept_result, _}`; the
  shell adds its own `pid` to `attrs`.
  """
  @type effect ::
          {:join_queue, map()}
          | :leave_queue
          | {:invite, map()}
          | :cancel_invitation
          | {:accept_invitation, String.t(), map()}
          | {:hang_up, pid()}
          | {:vote, pid(), :continue | :end}
          | {:relay_signal, pid(), String.t(), map()}
          | {:push_signal, map()}
          | {:push_resume_ticket, String.t()}
          | :detach

  @type t :: %__MODULE__{
          id: String.t(),
          topic: String.t(),
          preferences: preferences(),
          status: status(),
          call_pid: pid() | nil,
          call: Call.t() | nil,
          webrtc_role: :offerer | :answerer | nil,
          stop_after_call?: boolean(),
          invitation: invitation() | nil,
          call_kind: Match.kind() | nil,
          notice: :call_ended | nil,
          error: error() | nil
        }

  @enforce_keys [:id, :topic, :preferences]
  defstruct [
    :id,
    :topic,
    :preferences,
    :call_pid,
    :call,
    :webrtc_role,
    :error,
    :invitation,
    :call_kind,
    :notice,
    status: :idle,
    stop_after_call?: false
  ]

  @end_call_reasons [:microphone_denied, :microphone_not_found, :audio_unavailable, :audio_failed]

  @in_call [:connecting, :in_call, :extension_pending]

  @doc """
  A new idle participant with a random anonymous id and its PubSub topic.
  """
  @spec new(preferences()) :: t()
  def new(preferences) do
    id = "anon-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    %__MODULE__{id: id, topic: "participant:#{id}", preferences: preferences}
  end

  @doc """
  The participant a resumed connection takes over (`RandosWeb.ParticipantShell.resume/1`):
  the same id and topic, in the same call, from the call's own record of
  them (`entry`, their queue entry). They had agreed to the terms to be
  matched at all.
  """
  @spec resumed(Randos.Matchmaking.Entry.t(), Call.t()) :: t()
  def resumed(entry, %Call{} = call) do
    preferences = %{
      speaks: entry.speaks_language,
      hears: entry.hears_languages,
      adult_acknowledged?: true,
      audio?: entry.audio?,
      ice_restart?: entry.ice_restart?
    }

    p = %__MODULE__{
      id: entry.id,
      topic: entry.topic,
      preferences: preferences,
      call_pid: call.pid,
      call_kind: call.match.kind,
      webrtc_role: Match.webrtc_role(call.match, entry.id)
    }

    {p, []} = update_call(p, call)
    p
  end

  @doc "Applies one event, returning the new participant and the effects to run."
  @spec handle(t(), event()) :: {t(), [effect()]}

  # Choosing languages and looking for someone.

  def handle(p, {:update_preferences, preferences}), do: {%{p | preferences: preferences}, []}

  def handle(%{status: :idle} = p, {:find, preferences}) do
    p = %{p | preferences: preferences, error: nil, notice: nil}

    if preferences.adult_acknowledged? do
      {p, [{:join_queue, join_attrs(p)}]}
    else
      {%{p | error: :adult_terms_required}, []}
    end
  end

  def handle(%{status: :looking} = p, :cancel_search), do: {%{p | status: :idle}, [:leave_queue]}

  # Inviting someone instead, or joining through someone's link.

  def handle(%{status: :idle} = p, {:invite, preferences}) do
    p = %{p | preferences: preferences, error: nil, notice: nil}

    if preferences.adult_acknowledged? do
      {p, [{:invite, join_attrs(p)}]}
    else
      {%{p | error: :adult_terms_required}, []}
    end
  end

  def handle(%{status: :inviting} = p, :cancel_invitation),
    do: {%{p | status: :idle, invitation: nil}, [:cancel_invitation]}

  def handle(%{status: :inviting} = p, :invitation_expired),
    do: {%{p | status: :idle, invitation: nil, error: :invitation_expired}, []}

  # The joiner names no languages (the creator's decide), only these.
  def handle(%{status: :idle} = p, {:accept_invitation, token, preferences}) do
    p = %{p | preferences: Map.merge(p.preferences, preferences), error: nil, notice: nil}

    if p.preferences.adult_acknowledged? do
      {p, [{:accept_invitation, token, join_attrs(p)}]}
    else
      {%{p | error: :adult_terms_required}, []}
    end
  end

  def handle(p, {:invite_result, {:invited, token, expires_at}}),
    do:
      {%{p | status: :inviting, invitation: %{token: token, expires_at_unix_ms: expires_at}}, []}

  def handle(p, {:invite_result, {:error, :already_queued}}), do: {p, []}
  def handle(p, {:invite_result, {:error, reason}}), do: {%{p | status: :idle, error: reason}, []}

  def handle(p, {:accept_result, {:matched, _match} = result}), do: {join_result(p, result), []}
  def handle(p, {:accept_result, {:error, :already_queued}}), do: {p, []}
  def handle(p, {:accept_result, {:error, reason}}), do: {%{p | status: :idle, error: reason}, []}

  def handle(p, {:join_result, result}), do: {join_result(p, result), []}

  # Calls, as reported by their coordinator.

  def handle(p, {:call_updated, %Call{} = call}) do
    cond do
      not Match.member?(call.match, p.id) ->
        {p, []}

      call.pid == p.call_pid ->
        update_call(p, call)

      p.status in [:looking, :inviting] and call.status != :ended ->
        update_call(adopt(p, call), call)

      p.status == :idle and call.status != :ended ->
        {p, [{:hang_up, call.pid}]}

      true ->
        {p, []}
    end
  end

  # Leaving or extending the current call.

  def handle(%{status: status} = p, :end_call) when status in @in_call do
    {%{p | stop_after_call?: true}, [{:hang_up, p.call_pid}]}
  end

  def handle(%{status: status} = p, {:end_call, reason})
      when status in @in_call and reason in @end_call_reasons do
    {%{p | stop_after_call?: true, error: reason}, [{:hang_up, p.call_pid}]}
  end

  def handle(%{call_kind: :invitation} = p, :next), do: {p, []}

  def handle(%{status: status} = p, :next) when status in @in_call do
    {%{p | stop_after_call?: false}, [{:hang_up, p.call_pid}]}
  end

  def handle(%{status: :extension_pending} = p, {:vote, vote}) when vote in [:continue, :end] do
    {%{p | stop_after_call?: vote == :end}, [{:vote, p.call_pid, vote}]}
  end

  # WebRTC signaling between this participant's client and their peer.

  def handle(%{status: status} = p, {:client_signal, type, payload}) when status in @in_call do
    {p, [{:relay_signal, p.call_pid, type, payload}]}
  end

  def handle(%{call: %Call{id: call_id}} = p, {:signaling, %{call_id: call_id} = message}) do
    {p, [{:push_signal, client_signal(message)}]}
  end

  # Resuming after a dropped connection: the current call's ticket goes to
  # the client (it holds it in memory only); if another connection took
  # this participant's seat, this one steps aside.
  def handle(%{call_pid: pid} = p, {:resume_ticket, pid, ticket}) when is_pid(pid),
    do: {p, [{:push_resume_ticket, ticket}]}

  def handle(%{call_pid: pid} = p, {:resumed_elsewhere, pid}) when is_pid(pid),
    do:
      {%{p | call_pid: nil, call: nil, webrtc_role: nil, call_kind: nil, status: :idle},
       [:detach]}

  # Anything else doesn't apply in the current status.
  def handle(p, _event), do: {p, []}

  ## Helpers

  defp join_result(p, :queued), do: %{p | status: :looking}
  defp join_result(p, {:error, :already_queued}), do: %{p | status: :looking}

  defp join_result(p, {:matched, match}) do
    %{
      p
      | status: :connecting,
        call_pid: match.call_pid,
        call: nil,
        call_kind: match.kind,
        invitation: nil,
        webrtc_role: Match.webrtc_role(match, p.id),
        stop_after_call?: false,
        error: nil
    }
  end

  defp join_result(p, {:error, reason}), do: %{p | status: :idle, error: reason}

  defp adopt(p, call) do
    %{
      p
      | call_pid: call.pid,
        call_kind: call.match.kind,
        invitation: nil,
        webrtc_role: Match.webrtc_role(call.match, p.id),
        stop_after_call?: false,
        error: nil
    }
  end

  defp update_call(p, %Call{status: :ended} = call) do
    p = %{p | call_pid: nil, call: nil, call_kind: nil, webrtc_role: nil}

    cond do
      p.stop_after_call? ->
        {%{p | status: :idle, stop_after_call?: false}, []}

      call.match.kind == :invitation ->
        {%{p | status: :idle, notice: :call_ended}, []}

      true ->
        {%{p | status: :looking}, [{:join_queue, join_attrs(p)}]}
    end
  end

  defp update_call(p, %Call{} = call) do
    status =
      case call.status do
        :connecting -> :connecting
        :active -> :in_call
        :extension_pending -> :extension_pending
      end

    {%{p | call: call, status: status}, []}
  end

  defp join_attrs(p) do
    %{
      id: p.id,
      topic: p.topic,
      speaks_language: p.preferences.speaks,
      hears_languages: p.preferences.hears,
      accepted_adult_terms: p.preferences.adult_acknowledged?,
      audio?: p.preferences.audio?,
      ice_restart?: Map.get(p.preferences, :ice_restart?, false)
    }
  end

  # What the browser needs from a peer's signal. Participant ids stay on the
  # server: the peer should never learn a stable identifier for you.
  defp client_signal(message) do
    %{
      call_id: message.call_id,
      type: Atom.to_string(message.type),
      payload: message.payload,
      sent_at_unix_ms: message.sent_at_unix_ms
    }
  end

  @doc "Reads a client's `end_call` reason (from JSON); only the documented ones."
  @spec cast_end_call_reason(String.t()) :: {:ok, end_call_reason()} | :error
  def cast_end_call_reason(reason) when is_binary(reason) do
    case Enum.find(@end_call_reasons, &(Atom.to_string(&1) == reason)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end
end
