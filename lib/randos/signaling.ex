defmodule Randos.Signaling do
  @moduledoc """
  Message boundary for peer-to-peer WebRTC signaling.

  Phoenix relays these messages between matched browser sessions. It does not
  inspect, transform, store, or process media.
  """

  alias Randos.Matchmaking.Match

  # Relayed to the peer untouched.
  @media_types [:offer, :answer, :ice_candidate]

  # What a client reports about itself; the server acts on these and never
  # relays them. `media_state` is the client's raw connection state (the
  # call coordinator owns timeouts and failure); `peer_disconnected` means
  # "I'm leaving". `connection_established` / `connection_failed` are the
  # older spelling of `media_state` connected / failed, still accepted for
  # pages loaded before the change.
  @lifecycle_types [:media_state, :peer_disconnected, :connection_established, :connection_failed]

  @media_states ~w(connected disconnected failed)

  @types @media_types ++ @lifecycle_types

  @type type ::
          :offer
          | :answer
          | :ice_candidate
          | :media_state
          | :connection_established
          | :connection_failed
          | :peer_disconnected

  @type message :: %{
          call_id: String.t(),
          type: type(),
          from_participant_id: String.t(),
          to_participant_id: String.t(),
          payload: map(),
          sent_at_unix_ms: integer()
        }

  @doc """
  Returns all supported signaling message types.
  """
  @spec supported_types() :: [type()]
  def supported_types, do: @types

  @doc """
  Casts user/client input into a supported signaling type.
  """
  @spec cast_type(atom() | String.t()) :: {:ok, type()} | {:error, :unsupported_signal_type}
  def cast_type(type) when is_atom(type) do
    if type in @types do
      {:ok, type}
    else
      {:error, :unsupported_signal_type}
    end
  end

  def cast_type(type) when is_binary(type) do
    type
    |> String.trim()
    |> String.to_existing_atom()
    |> cast_type()
  rescue
    ArgumentError -> {:error, :unsupported_signal_type}
  end

  @doc """
  Builds a relay message for the participant's peer.
  """
  @spec build_message(Randos.Calls.Call.t(), String.t(), atom() | String.t(), map()) ::
          {:ok, message()} | {:error, :unknown_participant | :unsupported_signal_type}
  def build_message(call, from_participant_id, type, payload \\ %{}) do
    with {:ok, type} <- cast_type(type),
         {:ok, peer} <- Match.peer(call.match, from_participant_id) do
      {:ok,
       %{
         call_id: call.id,
         type: type,
         from_participant_id: from_participant_id,
         to_participant_id: peer.id,
         payload: payload || %{},
         sent_at_unix_ms: System.system_time(:millisecond)
       }}
    end
  end

  @typedoc "What a signal means for the call (see `classify/2`)."
  @type action :: :relay | :leave | {:media, :connected | :disconnected | :failed}

  @doc """
  What the call coordinator should do with a signal: relay media signals to
  the peer, end the call when a participant leaves, or apply a media state
  report. `media_state` payloads are validated (`{"state": "connected" |
  "disconnected" | "failed"}`); the server acts on them.
  """
  @spec classify(type(), map()) :: {:ok, action()} | {:error, :invalid_media_state}
  def classify(type, _payload) when type in @media_types, do: {:ok, :relay}
  def classify(:peer_disconnected, _payload), do: {:ok, :leave}
  def classify(:connection_established, _payload), do: {:ok, {:media, :connected}}
  def classify(:connection_failed, _payload), do: {:ok, {:media, :failed}}

  def classify(:media_state, %{"state" => state}) when state in @media_states,
    do: {:ok, {:media, String.to_existing_atom(state)}}

  def classify(:media_state, _payload), do: {:error, :invalid_media_state}
end
