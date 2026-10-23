defmodule Randos.Calls.Lifecycle do
  @moduledoc """
  Pure call lifecycle rules: timing constants and status transitions.

      :connecting ──activate──▶ :active ──request_extension──▶ :extension_pending
           │                      ▲  │                               │
           │                      │  └──────────── end_call ───────┤
           │                      └───────────── extend ───────────┤
           └─────────────────────── end_call ──────────────────────┴──▶ :ended

  Calls start at ten minutes; each extension (both people must agree) adds
  ten more, up to two extensions and thirty minutes total.

  A call carries audio when its participants do (`Entry.audio?`). Then it
  stays `:connecting` until both report their media `:connected`, and the ten
  minutes start only then; if that takes longer than the connect timeout,
  the call ends `:connection_failed`. Once active, a call that turns
  unhealthy (someone's media down, or someone's connection to the server
  gone) has one recovery budget to come back, with ICE restarts inside it
  when both clients support them; past it, it ends. The server owns these
  rules so the browser and the TUI don't each implement them.

  Transitions from the wrong status raise `FunctionClauseError`: callers are
  expected to know the current status. The one legitimate refusal is
  `extend/1` once the extension cap is reached.
  """

  alias Randos.Calls.Call

  @type ended_reason ::
          :canceled
          | :completed
          | :extension_declined
          | :extension_timeout
          | :hangup
          | :disconnected
          | :connection_failed
          | :peer_disconnected
          | :max_duration_reached

  @ended_reasons [
    :canceled,
    :completed,
    :extension_declined,
    :extension_timeout,
    :hangup,
    :disconnected,
    :connection_failed,
    :peer_disconnected,
    :max_duration_reached
  ]

  @call_duration_seconds 600
  @extension_duration_seconds 600
  @max_extension_count 2
  @extension_response_timeout_seconds 20
  @connect_timeout_seconds 15
  @rematch_window_seconds 90
  @recovery_budget_seconds 15
  @offline_slack_seconds 2
  @ice_restart_delay_seconds 2
  @ice_restart_retry_seconds 5

  @typedoc "One participant's media, as they last reported it."
  @type media_state :: :connecting | :connected | :disconnected

  @spec call_duration_seconds() :: pos_integer()
  def call_duration_seconds, do: @call_duration_seconds

  @spec extension_duration_seconds() :: pos_integer()
  def extension_duration_seconds, do: @extension_duration_seconds

  @spec max_extension_count() :: non_neg_integer()
  def max_extension_count, do: @max_extension_count

  @spec max_call_duration_seconds() :: pos_integer()
  def max_call_duration_seconds,
    do: @call_duration_seconds + @max_extension_count * @extension_duration_seconds

  @spec extension_response_timeout_seconds() :: pos_integer()
  def extension_response_timeout_seconds, do: @extension_response_timeout_seconds

  @doc "How long a call with audio may take to connect both sides (configurable per call)."
  @spec connect_timeout_seconds() :: pos_integer()
  def connect_timeout_seconds, do: @connect_timeout_seconds

  @doc """
  How long two people who just had a call aren't matched with each other
  again (so "Next" finds someone new), counted from the call's end.
  """
  @spec rematch_window_seconds() :: pos_integer()
  def rematch_window_seconds, do: @rematch_window_seconds

  @doc """
  How long an active call may stay unhealthy (someone's media down, or
  someone's connection to the server dropped: a network change, a sleeping
  laptop) before it ends, whatever the cause and whatever the clients can
  do about it. Restarts and resumes happen inside it.
  """
  @spec recovery_budget_seconds() :: pos_integer()
  def recovery_budget_seconds, do: @recovery_budget_seconds

  @doc """
  How long a client keeps a call's media running while it can't reach the
  server (obligation 11): the recovery budget, past which the server has
  ended the call, and a little slack so the server's own timer decides
  first. A client can't ask the server then, so this is the one call
  timer clients run, and the server tells them its length.
  """
  @spec offline_limit_seconds() :: pos_integer()
  def offline_limit_seconds, do: @recovery_budget_seconds + @offline_slack_seconds

  @doc """
  ICE restart (calls whose two clients support it, `Call.ice_restart?`):
  how long a side may stay `disconnected` before the server asks for a
  restart (a short loss often recovers by itself). `failed` doesn't wait.
  """
  @spec ice_restart_delay_seconds() :: pos_integer()
  def ice_restart_delay_seconds, do: @ice_restart_delay_seconds

  @doc "How often the server asks again while a restarted call is still down."
  @spec ice_restart_retry_seconds() :: pos_integer()
  def ice_restart_retry_seconds, do: @ice_restart_retry_seconds

  @spec ended_reasons() :: [ended_reason()]
  def ended_reasons, do: @ended_reasons

  @doc "Whether this call carries audio (both participants' clients do)."
  @spec audio?(Call.t()) :: boolean()
  def audio?(%Call{match: match}), do: match.participant_a.audio? and match.participant_b.audio?

  @doc "Records one participant's media state."
  @spec put_media(Call.t(), String.t(), media_state()) :: Call.t()
  def put_media(%Call{} = call, participant_id, state)
      when state in [:connecting, :connected, :disconnected],
      do: %{call | media: Map.put(call.media, participant_id, state)}

  @doc "Both participants' media is connected."
  @spec media_connected?(Call.t()) :: boolean()
  def media_connected?(%Call{match: match, media: media}) do
    Map.get(media, match.participant_a.id) == :connected and
      Map.get(media, match.participant_b.id) == :connected
  end

  @doc "Both peers are connected: start the call clock."
  @spec activate(Call.t()) :: Call.t()
  def activate(%Call{status: :connecting} = call), do: %{call | status: :active}

  @doc "Time is up: ask both participants whether to continue."
  @spec request_extension(Call.t()) :: Call.t()
  def request_extension(%Call{status: :active} = call) do
    %{call | status: :extension_pending, call_deadline_unix_ms: nil, continuing: []}
  end

  @doc "Both participants voted to continue."
  @spec extend(Call.t()) :: {:ok, Call.t()} | {:error, :max_extensions}
  def extend(%Call{status: :extension_pending, extension_count: count})
      when count >= @max_extension_count,
      do: {:error, :max_extensions}

  def extend(%Call{status: :extension_pending} = call) do
    {:ok,
     %{
       call
       | status: :active,
         extension_count: call.extension_count + 1,
         extension_deadline_unix_ms: nil,
         continuing: []
     }}
  end

  @doc "Ends a call that hasn't ended yet."
  @spec end_call(Call.t(), ended_reason()) :: Call.t()
  def end_call(%Call{status: status} = call, reason)
      when status != :ended and reason in @ended_reasons do
    %{call | status: :ended, ended_reason: reason}
  end
end
