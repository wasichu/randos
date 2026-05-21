defmodule Randos.Signaling do
  @moduledoc """
  Message boundary for future peer-to-peer WebRTC signaling.

  Phoenix relays these messages between matched browser sessions. It does not
  inspect, transform, store, or process media.
  """

  @media_types [:offer, :answer, :ice_candidate]

  @lifecycle_types [
    :hangup,
    :peer_disconnected,
    :connection_failed,
    :connection_established,
    :time_limit_reached,
    :extension_requested,
    :extension_accepted,
    :extension_declined,
    :extension_confirmed,
    :extension_timeout
  ]

  @types @media_types ++ @lifecycle_types

  @type type ::
          :offer
          | :answer
          | :ice_candidate
          | :hangup
          | :peer_disconnected
          | :connection_failed
          | :connection_established
          | :time_limit_reached
          | :extension_requested
          | :extension_accepted
          | :extension_declined
          | :extension_confirmed
          | :extension_timeout

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
  @spec build_message(map(), String.t(), atom() | String.t(), map()) ::
          {:ok, message()} | {:error, :unknown_participant | :unsupported_signal_type}
  def build_message(call, from_participant_id, type, payload \\ %{}) do
    with {:ok, type} <- cast_type(type),
         {:ok, peer} <- peer_for(call.match, from_participant_id) do
      {:ok,
       %{
         call_id: call.call_id,
         type: type,
         from_participant_id: from_participant_id,
         to_participant_id: peer.id,
         payload: payload || %{},
         sent_at_unix_ms: System.system_time(:millisecond)
       }}
    end
  end

  @doc """
  Returns the peer participant for a call match.
  """
  @spec peer_for(map(), String.t()) :: {:ok, map()} | {:error, :unknown_participant}
  def peer_for(match, participant_id) do
    cond do
      match.participant_a.id == participant_id -> {:ok, match.participant_b}
      match.participant_b.id == participant_id -> {:ok, match.participant_a}
      true -> {:error, :unknown_participant}
    end
  end

  @doc """
  Returns the deterministic WebRTC role assigned during matchmaking.
  """
  @spec webrtc_role_for(map(), String.t()) :: :offerer | :answerer | nil
  def webrtc_role_for(match, participant_id) do
    participant_role =
      cond do
        match.participant_a.id == participant_id -> :participant_a
        match.participant_b.id == participant_id -> :participant_b
        true -> nil
      end

    cond do
      participant_role == match.offerer -> :offerer
      participant_role == match.answerer -> :answerer
      true -> nil
    end
  end
end
