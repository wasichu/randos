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
          match: Randos.Matchmaking.Match.t(),
          status: status(),
          extension_count: non_neg_integer(),
          call_deadline_unix_ms: integer() | nil,
          extension_deadline_unix_ms: integer() | nil,
          ended_reason: Randos.Calls.Lifecycle.ended_reason() | nil,
          media: %{String.t() => Randos.Calls.Lifecycle.media_state()}
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
    extension_count: 0,
    media: %{}
  ]

  @doc """
  Builds a new `:connecting` call with a random, unguessable id.
  """
  @spec new(pid(), Randos.Matchmaking.Match.t()) :: t()
  def new(pid, match) do
    %__MODULE__{
      id: "call-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      pid: pid,
      match: match,
      media: %{match.participant_a.id => :connecting, match.participant_b.id => :connecting}
    }
  end
end
