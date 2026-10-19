defmodule Randos.Calls.Call do
  @moduledoc """
  The public state of one matched call.

  `Randos.Calls.CallCoordinator` owns the only copy and broadcasts it to both
  participants on every lifecycle change. Transitions live in
  `Randos.Calls.Lifecycle`.
  """

  @type status :: :connecting | :active | :extension_pending | :ended

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          match: map(),
          status: status(),
          extension_count: non_neg_integer(),
          call_deadline_unix_ms: integer() | nil,
          extension_deadline_unix_ms: integer() | nil,
          ended_reason: Randos.Calls.Lifecycle.ended_reason() | nil
        }

  @enforce_keys [:id, :pid, :match]
  defstruct [
    :id,
    :pid,
    :match,
    :call_deadline_unix_ms,
    :extension_deadline_unix_ms,
    :ended_reason,
    status: :connecting,
    extension_count: 0
  ]

  @doc """
  Builds a new `:connecting` call with a random, unguessable id.
  """
  @spec new(pid(), map()) :: t()
  def new(pid, match) do
    %__MODULE__{
      id: "call-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      pid: pid,
      match: match
    }
  end
end
