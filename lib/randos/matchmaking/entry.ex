defmodule Randos.Matchmaking.Entry do
  @moduledoc """
  One person in the matchmaking queue: who they are, where to reach them,
  which languages they want, and whether their client carries call audio.
  Matches pair two entries.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          topic: String.t(),
          speaks_language: String.t(),
          listens_language: String.t(),
          audio?: boolean()
        }

  @enforce_keys [:id, :pid, :topic, :speaks_language, :listens_language, :audio?]
  defstruct @enforce_keys
end
