defmodule Randos.Matchmaking.Entry do
  @moduledoc """
  One person in the matchmaking queue: who they are, where to reach them, and
  which languages they want. Matches pair two entries.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          topic: String.t(),
          speaks_language: String.t(),
          listens_language: String.t()
        }

  @enforce_keys [:id, :pid, :topic, :speaks_language, :listens_language]
  defstruct @enforce_keys
end
