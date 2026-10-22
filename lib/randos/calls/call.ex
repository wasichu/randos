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
          media: %{String.t() => Randos.Calls.Lifecycle.media_state()},
          ice_transport_policy: ice_transport_policy(),
          away: [String.t()],
          ice_restart?: boolean(),
          ice_generation: non_neg_integer(),
          recovering: boolean()
        }

  @typedoc """
  `"relay"`: only through the TURN relay, so neither person learns the
  other's address (the coordinator enforces it on relayed signals);
  `"all"`: direct when possible.
  """
  @type ice_transport_policy :: String.t()

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
    media: %{},
    ice_transport_policy: "all",
    # Participants whose connection to the server dropped, waiting for them
    # to come back (within Lifecycle.recovery_budget_seconds/0).
    away: [],
    # Both clients can restart ICE (obligation 10); otherwise the call
    # keeps the plain disconnected grace.
    ice_restart?: false,
    # Bumped by the coordinator to ask the offerer for an ICE restart.
    ice_generation: 0,
    # Unhealthy (someone's media down, or someone away) and within the
    # recovery budget; clients say "Reconnecting audio…".
    recovering: false
  ]

  @doc """
  Builds a new `:connecting` call with a random, unguessable id.
  """
  @spec new(pid(), Randos.Matchmaking.Match.t(), ice_transport_policy()) :: t()
  def new(pid, match, ice_transport_policy \\ "all") do
    %__MODULE__{
      ice_transport_policy: ice_transport_policy,
      id: "call-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      pid: pid,
      match: match,
      media: %{match.participant_a.id => :connecting, match.participant_b.id => :connecting},
      ice_restart?: match.participant_a.ice_restart? and match.participant_b.ice_restart?
    }
  end
end
