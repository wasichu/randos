defmodule Randos.Matchmaking.Match do
  @moduledoc """
  Two compatible queue entries paired by the matchmaker.

  `participant_a` was waiting first and makes the WebRTC offer;
  `participant_b` answers. `call_pid` is the call's coordinator, set once it
  has started. `kind` is `:invitation` for two people who came through an
  invitation link (both go idle after the call, and it has no "Next"),
  else `:random`.
  """

  alias Randos.Matchmaking.Entry

  @type t :: %__MODULE__{
          id: String.t(),
          participant_a: Entry.t(),
          participant_b: Entry.t(),
          call_pid: pid() | nil,
          kind: kind()
        }

  @type kind :: :random | :invitation

  @enforce_keys [:id, :participant_a, :participant_b]
  defstruct [:id, :participant_a, :participant_b, :call_pid, kind: :random]

  @doc """
  Pairs a waiting entry (`a`, the offerer: an invitation's creator) with a
  newly joined one (`b`).
  """
  @spec new(Entry.t(), Entry.t(), kind()) :: t()
  def new(%Entry{} = a, %Entry{} = b, kind \\ :random) do
    id = "match-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {a, b} = select_languages(a, b, kind)
    %__MODULE__{id: id, participant_a: a, participant_b: b, kind: kind}
  end

  # Stable code order breaks ties without changing oldest-compatible queue policy.
  # Only the call's copies change; offered_languages survives resume and requeue.
  defp select_languages(a, b, :random) do
    {select_language(a, b.hears_languages), select_language(b, a.hears_languages)}
  end

  defp select_languages(a, b, :invitation), do: {a, b}

  defp select_language(entry, hears) do
    code = entry |> Entry.offered_languages() |> Enum.sort() |> Enum.find(&(&1 in hears))
    %{entry | speaks_language: code, speaks_any: nil}
  end

  @doc "Whether `participant_id` is one of the two people in the match."
  @spec member?(t(), String.t()) :: boolean()
  def member?(%__MODULE__{} = match, participant_id) do
    participant_id in [match.participant_a.id, match.participant_b.id]
  end

  @doc "The other person in the match."
  @spec peer(t(), String.t()) :: {:ok, Entry.t()} | {:error, :unknown_participant}
  def peer(%__MODULE__{participant_a: %{id: id}, participant_b: b}, id), do: {:ok, b}
  def peer(%__MODULE__{participant_a: a, participant_b: %{id: id}}, id), do: {:ok, a}
  def peer(%__MODULE__{}, _participant_id), do: {:error, :unknown_participant}

  @doc "`:offerer` for participant A, `:answerer` for participant B."
  @spec webrtc_role(t(), String.t()) :: :offerer | :answerer | nil
  def webrtc_role(%__MODULE__{participant_a: %{id: id}}, id), do: :offerer
  def webrtc_role(%__MODULE__{participant_b: %{id: id}}, id), do: :answerer
  def webrtc_role(%__MODULE__{}, _participant_id), do: nil
end
