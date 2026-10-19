defmodule Tui.Media.State do
  @moduledoc """
  What the TUI knows about local audio, as pure transitions: each function
  takes the state and an input (a key, a helper reply or event, a timer) and
  returns `{state, commands}`. `Tui.App` runs the commands and never blocks
  on the helper. Stage 0 has one feature, the mic test; Stage 1 adds call
  audio here, not in the app.

  Commands:

    * `{:request, Tui.Media.Protocol.command()}`: send to `Tui.Media`; its
      reply comes back through `reply/3`
    * `{:after, ms, message}`: deliver `message` to the app later
  """

  alias Tui.Media.Protocol

  @mic_test_ms 5_000

  @type phase :: :starting | :running | :done | :failed
  @type mic_test :: %{phase: phase(), stats: map() | nil, error: String.t() | nil}
  @type command :: {:request, Protocol.command()} | {:after, non_neg_integer(), term()}
  @type t :: %__MODULE__{available?: boolean(), mic_test: mic_test() | nil}

  defstruct available?: false, mic_test: nil

  @doc "`available?`: whether this TUI was started with a media helper at all."
  @spec new(boolean()) :: t()
  def new(available?), do: %__MODULE__{available?: available?}

  @doc "The user asked for a mic test, through `{input, output}` (see `Tui.Media.loopback_start/3`)."
  @spec start_mic_test(t(), {String.t(), String.t()}) :: {t(), [command()]}
  def start_mic_test(%{mic_test: %{phase: phase}} = state, _endpoints)
      when phase in [:starting, :running],
      do: {state, []}

  def start_mic_test(%{available?: false} = state, _endpoints),
    do: {fail(state, "no audio helper (cargo build -p randos_media)"), []}

  def start_mic_test(state, {input, output}) do
    {%{state | mic_test: %{phase: :starting, stats: nil, error: nil}},
     [{:request, {:loopback_start, input, output}}]}
  end

  @doc "The helper's reply to a request this module issued."
  @spec reply(t(), Protocol.command(), {:ok, term()} | {:error, String.t()}) ::
          {t(), [command()]}
  def reply(%{mic_test: %{phase: :starting}} = state, {:loopback_start, _, _}, {:ok, _opened}) do
    {put_mic_test(state, phase: :running), [{:after, @mic_test_ms, :mic_test_done}]}
  end

  def reply(%{mic_test: %{phase: :starting}} = state, {:loopback_start, _, _}, {:error, error}),
    do: {fail(state, error), []}

  def reply(state, _command, _result), do: {state, []}

  @doc "An unsolicited helper event (`{:media, name, payload}` from `Tui.Media`)."
  @spec event(t(), String.t(), map()) :: t()
  def event(%{mic_test: %{phase: :running}} = state, "loopback_stats", stats),
    do: put_mic_test(state, stats: stats)

  def event(%{mic_test: %{phase: phase}} = state, "loopback_failed", %{"error" => error})
      when phase in [:starting, :running],
      do: fail(state, error)

  # A fresh helper: whatever was running died with the old one.
  def event(%{mic_test: %{phase: phase}} = state, "ready", _payload)
      when phase in [:starting, :running],
      do: fail(state, "the audio helper restarted")

  def event(state, _name, _payload), do: state

  @doc "The mic test's time is up."
  @spec mic_test_done(t()) :: {t(), [command()]}
  def mic_test_done(%{mic_test: %{phase: :running}} = state),
    do: {put_mic_test(state, phase: :done), [{:request, :loopback_stop}]}

  def mic_test_done(state), do: {state, []}

  defp fail(state, error) do
    mic_test = state.mic_test || %{stats: nil}
    %{state | mic_test: Map.merge(mic_test, %{phase: :failed, error: error})}
  end

  defp put_mic_test(state, changes),
    do: %{state | mic_test: Map.merge(state.mic_test, Map.new(changes))}
end
