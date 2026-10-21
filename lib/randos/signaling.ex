defmodule Randos.Signaling do
  @moduledoc """
  Message boundary for peer-to-peer WebRTC signaling.

  Phoenix relays these messages between matched participants. It never sees,
  stores, or processes media. It relays offers, answers, and ICE candidates
  as they are, with one exception: in a relay-only call,
  `relay_only/2` removes every address that could identify a person (see
  its doc for exactly what it changes), so a client that ignores the
  policy still can't reveal its owner's address to the peer.
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

  @doc """
  A media signal made safe for a relay-only call, or `:drop` when nothing of
  it may reach the peer. Only these change, and nothing else in the message
  (a test checks that fingerprints, ICE credentials, codecs and the rest
  stay byte for byte the same):

    * an ICE candidate that isn't a relay candidate (`typ host`, `srflx`,
      `prflx`) is dropped; so is one that can't be parsed;
    * a relay candidate's related address (`raddr`, `rport`: the address
      behind the relay) becomes `0.0.0.0 0`;
    * in an offer or answer's SDP, the same for its `a=candidate:` lines,
      and the addresses in `c=`, `a=rtcp:` and `o=` become `0.0.0.0` (`::`
      for IPv6). ICE doesn't use those; browsers and str0m already write
      `0.0.0.0` there in relay-only calls.

  The end-of-candidates signal (an empty candidate) passes unchanged.
  """
  @spec relay_only(type(), map()) :: {:ok, map()} | :drop
  def relay_only(:ice_candidate, %{"candidate" => %{"candidate" => line} = candidate} = payload)
      when is_binary(line) do
    case relay_candidate(line) do
      {:ok, line} -> {:ok, %{payload | "candidate" => %{candidate | "candidate" => line}}}
      :drop -> :drop
    end
  end

  def relay_only(type, %{"sdp" => %{"sdp" => sdp} = description} = payload)
      when type in [:offer, :answer] and is_binary(sdp),
      do: {:ok, %{payload | "sdp" => %{description | "sdp" => relay_only_sdp(sdp)}}}

  def relay_only(_type, _payload), do: :drop

  defp relay_only_sdp(sdp) do
    # Keep the line endings exactly as sent (CRLF, per the spec).
    sdp
    |> String.split(~r/(?<=\n)/)
    |> Enum.flat_map(&relay_only_sdp_line/1)
    |> Enum.join()
  end

  defp relay_only_sdp_line("a=candidate:" <> _ = line) do
    {body, ending} = split_ending(line)

    case relay_candidate(String.replace_prefix(body, "a=", "")) do
      {:ok, candidate} -> ["a=" <> candidate <> ending]
      :drop -> []
    end
  end

  defp relay_only_sdp_line("c=" <> _ = line), do: [zero_address(line)]
  defp relay_only_sdp_line("a=rtcp:" <> _ = line), do: [zero_address(line)]
  defp relay_only_sdp_line("o=" <> _ = line), do: [zero_address(line)]
  defp relay_only_sdp_line(line), do: [line]

  # "...IN IP4 <address>" (the last field, before the line ending; `c=` has
  # no space before "IN").
  defp zero_address(line) do
    {body, ending} = split_ending(line)
    Regex.replace(~r/IN IP(4|6) \S+$/, body, fn _, v -> "IN IP#{v} #{zero(v)}" end) <> ending
  end

  defp zero("4"), do: "0.0.0.0"
  defp zero("6"), do: "::"

  # The end-of-candidates signal.
  defp relay_candidate(""), do: {:ok, ""}

  defp relay_candidate("candidate:" <> _ = line) do
    fields = String.split(line, " ")

    if relay_type?(fields), do: {:ok, zero_related(fields)}, else: :drop
  end

  defp relay_candidate(_line), do: :drop

  defp relay_type?(fields) do
    case Enum.drop_while(fields, &(&1 != "typ")) do
      ["typ", "relay" | _] -> true
      _other -> false
    end
  end

  defp zero_related(fields), do: fields |> zero_related([]) |> Enum.join(" ")

  defp zero_related(["raddr", _address | rest], acc),
    do: zero_related(rest, ["0.0.0.0", "raddr" | acc])

  defp zero_related(["rport", _port | rest], acc), do: zero_related(rest, ["0", "rport" | acc])
  defp zero_related([field | rest], acc), do: zero_related(rest, [field | acc])
  defp zero_related([], acc), do: Enum.reverse(acc)

  defp split_ending(line) do
    case Regex.run(~r/^(.*?)(\r?\n)?$/s, line, capture: :all_but_first) do
      [body, ending] -> {body, ending}
      [body] -> {body, ""}
    end
  end
end
