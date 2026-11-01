defmodule Randos.Matchmaking.Entry do
  @moduledoc """
  One person in the matchmaking queue: who they are, where to reach them,
  their offered speaking languages and the languages they're happy to hear, and
  whether their client carries call audio and can restart ICE (`ice_restart?`,
  not a matching rule: a call restarts only when both can). Matches pair two
  entries.

  `offered_languages` keeps the original speaking set for resume/requeue;
  nil supports legacy entries offering only `speaks_language`. A random
  match fixes `speaks_language` to one compatible code. `speaks_any` is
  only for invitations, where either person may speak several languages
  (nil: just `speaks_language`).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          topic: String.t(),
          speaks_language: String.t(),
          hears_languages: [String.t()],
          audio?: boolean(),
          ice_restart?: boolean(),
          speaks_any: [String.t()] | nil,
          offered_languages: [String.t()] | nil
        }

  @enforce_keys [:id, :pid, :topic, :speaks_language, :hears_languages, :audio?]
  defstruct @enforce_keys ++ [ice_restart?: false, speaks_any: nil, offered_languages: nil]

  @doc """
  Whether two people can talk: each one speaks a language the other is
  happy to hear (the same language both ways, or crosstalk), and their
  clients agree on carrying audio.
  """
  @spec compatible?(t(), t()) :: boolean()
  def compatible?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.audio? == b.audio? and
      Enum.any?(offered_languages(a), &(&1 in b.hears_languages)) and
      Enum.any?(offered_languages(b), &(&1 in a.hears_languages))
  end

  @doc "The full speaking choices, retained separately from the call's selected language."
  @spec offered_languages(t()) :: [String.t()]
  def offered_languages(%__MODULE__{offered_languages: codes}) when is_list(codes), do: codes
  def offered_languages(%__MODULE__{speaks_language: code}), do: [code]

  @doc "Every language the person may speak (`speaks_any`, else the one)."
  @spec speaks_any(t()) :: [String.t()]
  def speaks_any(%__MODULE__{speaks_any: [_ | _] = codes}), do: codes
  def speaks_any(%__MODULE__{speaks_language: code}), do: [code]
end
