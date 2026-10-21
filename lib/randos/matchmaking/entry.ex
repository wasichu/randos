defmodule Randos.Matchmaking.Entry do
  @moduledoc """
  One person in the matchmaking queue: who they are, where to reach them,
  the language they speak and the languages they're happy to hear, and
  whether their client carries call audio. Matches pair two entries.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          topic: String.t(),
          speaks_language: String.t(),
          hears_languages: [String.t()],
          audio?: boolean()
        }

  @enforce_keys [:id, :pid, :topic, :speaks_language, :hears_languages, :audio?]
  defstruct @enforce_keys

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
end
