defmodule Randos.ConversationFlow do
  @moduledoc """
  Centralized UI state transitions for the mocked conversation flow.
  """

  @type state :: :idle | :looking | :connecting | :in_call | :extension_pending

  @transitions %{
    idle: [:looking],
    looking: [:idle, :connecting],
    connecting: [:in_call, :idle],
    in_call: [:extension_pending, :looking, :idle],
    extension_pending: [:in_call, :looking, :idle]
  }

  @doc """
  Returns the allowed next states for a UI state.
  """
  @spec allowed_transitions(state()) :: [state()]
  def allowed_transitions(state), do: Map.fetch!(@transitions, state)

  @doc """
  Applies a state transition when it is allowed.
  """
  @spec transition(state(), state()) :: {:ok, state()} | {:error, :invalid_transition}
  def transition(from, to) when is_atom(from) and is_atom(to) do
    if to in allowed_transitions(from) do
      {:ok, to}
    else
      {:error, :invalid_transition}
    end
  end
end
