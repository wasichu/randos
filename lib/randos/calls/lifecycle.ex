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

  @spec ended_reasons() :: [ended_reason()]
  def ended_reasons, do: @ended_reasons

  @doc "Both peers are connected: start the call clock."
  @spec activate(Call.t()) :: Call.t()
  def activate(%Call{status: :connecting} = call), do: %{call | status: :active}

  @doc "Time is up: ask both participants whether to continue."
  @spec request_extension(Call.t()) :: Call.t()
  def request_extension(%Call{status: :active} = call) do
    %{call | status: :extension_pending, call_deadline_unix_ms: nil}
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
         extension_deadline_unix_ms: nil
     }}
  end

  @doc "Ends a call that hasn't ended yet."
  @spec end_call(Call.t(), ended_reason()) :: Call.t()
  def end_call(%Call{status: status} = call, reason)
      when status != :ended and reason in @ended_reasons do
    %{call | status: :ended, ended_reason: reason}
  end
end
