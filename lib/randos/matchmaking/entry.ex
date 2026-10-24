defmodule Randos.Matchmaking.Entry do
  @moduledoc """
  One person in the matchmaking queue: who they are, where to reach them,
  the language they speak and the languages they're happy to hear, and
  whether their client carries call audio and can restart ICE (`ice_restart?`,
  not a matching rule: a call restarts only when both can). Matches pair two
  entries.

  `speaks_any` is for an invitation's joiner, who names no language: taken
  to speak what the creator wants to hear, `speaks_language` is the first
  of those and `speaks_any` all of them (nil: just `speaks_language`).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          topic: String.t(),
          speaks_language: String.t(),
          hears_languages: [String.t()],
          audio?: boolean(),
          ice_restart?: boolean(),
          speaks_any: [String.t()] | nil
        }

  @enforce_keys [:id, :pid, :topic, :speaks_language, :hears_languages, :audio?]
  defstruct @enforce_keys ++ [ice_restart?: false, speaks_any: nil]

  @doc """
  Whether two people can talk: each one speaks a language the other is
  happy to hear (the same language both ways, or crosstalk), and their
  clients agree on carrying audio.
  """
  @spec compatible?(t(), t()) :: boolean()
  def compatible?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.audio? == b.audio? and a.speaks_language in b.hears_languages and
      b.speaks_language in a.hears_languages
  end

  @doc "Every language the person may speak (`speaks_any`, else the one)."
  @spec speaks_any(t()) :: [String.t()]
  def speaks_any(%__MODULE__{speaks_any: [_ | _] = codes}), do: codes
  def speaks_any(%__MODULE__{speaks_language: code}), do: [code]
end
