defmodule Randos.Participant do
  @moduledoc """
  The UI-agnostic core of one person using randos: their flow from choosing
  languages, through the queue, into calls and back.

  Pure and process-free. A shell (the LiveView today; a Channel/TUI later)
  feeds it events and runs the effects it returns:

      {participant, effects} = Participant.handle(participant, event)

  ## Statuses

      :idle ──find──▶ (join) ──▶ :looking ──matched──▶ :connecting ──▶ :in_call ◀─┐
        ▲                          │                                    │         │
        └──────── cancel_search ───┘                                    ▼         │
        ▲                                                       :extension_pending┘
        └── call ended + stop_after_call? ── (otherwise back to :looking) ◀──┘

  ## Which calls are mine

  A `{:call_updated, call}` is only considered when the participant is in
  `call.match`. Then:

    * it updates the current call when `call.pid` is the current `call_pid`;
    * it is adopted when the participant is `:looking` (the matchmaker paired
      us while we waited);
    * it is declined (`{:hang_up, pid}`) when the participant is `:idle`
      (they cancelled the search just as they were matched);
    * anything else is stale and ignored.

  Signaling is forwarded to the client only for the current call.
  """

  alias Randos.Calls.Call
  alias Randos.Matchmaking.Match
  alias Randos.Signaling

  @type status :: :idle | :looking | :connecting | :in_call | :extension_pending

  @typedoc """
  What the person asked for: the language they'll speak, and the languages
  they're happy to hear (`hears`, at least one). `audio?` is whether their
  client can carry call audio (WebRTC); only clients that agree on it are
  matched, so nobody sits through a silent call with a text-only client.
  """
  @type preferences :: %{
          speaks: String.t(),
          hears: [String.t()],
          adult_acknowledged?: boolean(),
          audio?: boolean()
        }

  @typedoc """
  Shown to the person. The `end_call_reason`s say why their own client
  ended a call it couldn't carry (no mic, no audio); they go back to idle,
  and only the peer is requeued.
  """
  @type error ::
          :adult_terms_required | :unsupported_language | :call_start_failed | end_call_reason()

  @type end_call_reason ::
          :microphone_denied | :microphone_not_found | :audio_unavailable | :audio_failed

  @type join_result :: Randos.Matchmaking.Matchmaker.join_result()

  @type event ::
          {:update_preferences, preferences()}
          | {:find, preferences()}
          | :cancel_search
          | :end_call
          | {:end_call, end_call_reason()}
          | :next
          | {:vote, :continue | :end}
          | {:client_signal, String.t(), map()}
          | {:join_result, join_result()}
          | {:call_updated, Call.t()}
          | {:signaling, Signaling.message()}

  @typedoc """
  Work for the shell. `{:join_queue, attrs}`'s result must be fed back as
  `{:join_result, result}`; the shell adds its own `pid` to `attrs`.
  """
  @type effect ::
          {:join_queue, map()}
          | :leave_queue
          | {:hang_up, pid()}
          | {:vote, pid(), :continue | :end}
          | {:relay_signal, pid(), String.t(), map()}
          | {:push_signal, map()}

  @type t :: %__MODULE__{
          id: String.t(),
          topic: String.t(),
          preferences: preferences(),
          status: status(),
          call_pid: pid() | nil,
          call: Call.t() | nil,
          webrtc_role: :offerer | :answerer | nil,
          stop_after_call?: boolean(),
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

  @doc "Applies one event, returning the new participant and the effects to run."
  @spec handle(t(), event()) :: {t(), [effect()]}

  # Choosing languages and looking for someone.

  def handle(p, {:update_preferences, preferences}), do: {%{p | preferences: preferences}, []}

  def handle(%{status: :idle} = p, {:find, preferences}) do
    p = %{p | preferences: preferences, error: nil}

    if preferences.adult_acknowledged? do
      {p, [{:join_queue, join_attrs(p)}]}
    else
      {%{p | error: :adult_terms_required}, []}
    end
  end

  def handle(%{status: :looking} = p, :cancel_search), do: {%{p | status: :idle}, [:leave_queue]}

  def handle(p, {:join_result, result}), do: {join_result(p, result), []}

  # Calls, as reported by their coordinator.

  def handle(p, {:call_updated, %Call{} = call}) do
    cond do
      not Match.member?(call.match, p.id) -> {p, []}
      call.pid == p.call_pid -> update_call(p, call)
      p.status == :looking and call.status != :ended -> update_call(adopt(p, call), call)
      p.status == :idle and call.status != :ended -> {p, [{:hang_up, call.pid}]}
      true -> {p, []}
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
        webrtc_role: Match.webrtc_role(call.match, p.id),
        stop_after_call?: false,
        error: nil
    }
  end

  defp update_call(p, %Call{status: :ended}) do
    p = %{p | call_pid: nil, call: nil, webrtc_role: nil}

    if p.stop_after_call? do
      {%{p | status: :idle, stop_after_call?: false}, []}
    else
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
      audio?: p.preferences.audio?
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
