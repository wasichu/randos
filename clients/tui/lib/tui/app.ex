defmodule Tui.App do
  @moduledoc """
  The terminal UI (an ex_ratatui callback-runtime app) over `Tui.Model`.

  Options:

    * `:uri` — participant websocket URL; the app starts its own
      `Tui.Connection` to it
    * `:connection` — use an existing connection pid instead (tests pass
      themselves and receive pushes as casts)
    * `:media` — the `Tui.Media` server (pid or name), if audio is available;
      `t` on the idle screen runs a short mic → speaker test through it
    * `:mic_test` — `{input, output}` for that test (default
      `{"device", "device"}`; tests use `{"sine", "null"}`)
    * `:test_pid` — receives `{:tui_model, app_pid, model}` after every change (tests)
  """
  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Tui.Connection
  alias Tui.Media
  alias Tui.Model

  @tick_ms 1_000
  @mic_test_ms 5_000

  @impl true
  def mount(opts) do
    {connection, owned?} =
      case Keyword.fetch(opts, :connection) do
        {:ok, pid} ->
          {pid, false}

        :error ->
          {:ok, pid} = Connection.start_link(uri: Keyword.fetch!(opts, :uri), owner: self())
          {pid, true}
      end

    Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     %{
       model: Model.new(now_ms()),
       connection: connection,
       owned?: owned?,
       uri: Keyword.get(opts, :uri, "(test)"),
       media: Keyword.get(opts, :media),
       mic_test_endpoints: Keyword.get(opts, :mic_test, {"device", "device"}),
       mic_test: nil,
       test_pid: Keyword.get(opts, :test_pid)
     }}
  end

  @impl true
  def handle_info({:randos, message}, state) do
    {model, commands} =
      case message do
        {:joined, reply} -> Model.joined(state.model, reply)
        {:push, event, payload} -> Model.push(state.model, event, payload)
        {:reply, event, reply} -> Model.reply(state.model, event, reply)
        :disconnected -> Model.disconnected(state.model)
      end

    {:noreply, apply_model(state, model, commands)}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, apply_model(state, Model.tick(state.model, now_ms()), [])}
  end

  def handle_info({:media, "loopback_stats", stats}, %{mic_test: %{running?: true}} = state),
    do: {:noreply, update_mic_test(state, stats: stats)}

  def handle_info({:media, "loopback_failed", %{"error" => error}}, %{mic_test: %{}} = state),
    do: {:noreply, update_mic_test(state, running?: false, error: error)}

  def handle_info(:mic_test_done, %{mic_test: %{running?: true}} = state) do
    _ = call_media(state.media, &Media.loopback_stop/1)
    {:noreply, update_mic_test(state, running?: false)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_event(%Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state),
    do: {:stop, state}

  def handle_event(%Event.Key{code: "q", kind: "press"}, state), do: {:stop, state}

  def handle_event(
        %Event.Key{code: "t", kind: "press"},
        %{model: %{connection: :connected, status: :idle}, mic_test: test} = state
      )
      when test == nil or not test.running? do
    {:noreply, start_mic_test(state)}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state) do
    {model, commands} = Model.key(state.model, code)
    {:noreply, apply_model(state, model, commands)}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing the channel ends our participant: the server takes us out of
    # the queue and ends any call.
    if state.owned?, do: GenServer.stop(state.connection)
  end

  ## Rendering

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header_area, main_area, log_area, help_area] =
      Layout.split(area, :vertical, [{:length, 3}, {:min, 8}, {:length, 8}, {:length, 1}])

    model = state.model

    [
      {header(state), header_area}
      | main(model, main_area, mic_test_text(state))
    ] ++
      [
        {%List{items: model.log, block: panel(" Events ")}, log_area},
        {%Paragraph{text: " " <> help(model) <> mic_help(state), style: %Style{fg: :dark_gray}},
         help_area}
      ]
  end

  # The idle form is a List so the selection marker keeps rows aligned
  # (Paragraph wrapping trims leading spaces).
  defp main(%{connection: :connected, status: :idle} = model, area, mic_test) do
    [form_area, text_area] = Layout.split(area, :vertical, [{:length, 5}, {:min, 0}])
    ack = if model.adult_acknowledged?, do: "[x]", else: "[ ]"

    form = %List{
      items: [
        "I will speak:     ◀ #{Model.language_name(model, :speaks)} ▶",
        "I want to hear:   ◀ #{Model.language_name(model, :listens)} ▶",
        "#{ack} I'm 18+ and OK with anonymous, unmoderated calls"
      ],
      selected: Enum.find_index([:speaks, :listens, :ack], &(&1 == model.focus)),
      highlight_symbol: "▶ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: panel(title(model))
    }

    error = if model.error, do: "Error: #{model.error}\n\n", else: ""

    [
      {form, form_area},
      {%Paragraph{text: error <> "Press Enter to find a rando." <> mic_test, wrap: true},
       text_area}
    ]
  end

  defp main(model, area, _mic_test) do
    [{%Paragraph{text: main_text(model), block: panel(title(model)), wrap: true}, area}]
  end

  defp header(%{model: model, uri: uri}) do
    connection = if model.connection == :connected, do: "connected", else: "connecting…"

    %Paragraph{
      text: "Text-only client: no audio yet.  #{connection} to #{uri}",
      block: panel(" Randos ")
    }
  end

  defp title(%{connection: :connecting}), do: " Connecting "
  defp title(%{status: :idle}), do: " Find a rando "
  defp title(%{status: :looking}), do: " Looking "
  defp title(%{status: :connecting}), do: " Matched "
  defp title(%{status: :in_call}), do: " In call "
  defp title(%{status: :extension_pending}), do: " Time is up "
  defp title(_model), do: " Randos "

  defp main_text(%{connection: :connecting}), do: "Connecting to the server…"

  defp main_text(%{status: :looking} = model) do
    "Looking for a rando who speaks #{Model.language_name(model, :listens)} " <>
      "and wants to hear #{Model.language_name(model, :speaks)}…"
  end

  defp main_text(%{status: :connecting}), do: "Matched! Starting the call…"

  defp main_text(%{status: :in_call} = model) do
    "You're in a call.#{time_left(model, " remaining")}\n\n" <>
      "This client has no audio yet: if the peer offers audio (a browser), " <>
      "the call ends and you go back to idle. Two terminal clients can stay " <>
      "in a call to try timers and extension votes."
  end

  defp main_text(%{status: :extension_pending} = model) do
    "Time is up. Continue for another 10 minutes?#{time_left(model, " to decide")}\n\n" <>
      "y: continue    n: end"
  end

  defp main_text(_model), do: ""

  defp time_left(model, suffix) do
    case Model.seconds_left(model) do
      nil -> ""
      seconds -> "  #{div(seconds, 60)}:#{pad(rem(seconds, 60))}#{suffix}"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp help(%{connection: :connecting}), do: "q quit"

  defp help(%{status: :idle}),
    do: "tab/↑↓ move  ←→ change language  space toggle 18+  enter find  q quit"

  defp help(%{status: :looking}), do: "c cancel  q quit"

  defp help(%{status: s}) when s in [:connecting, :in_call],
    do: "e end call  n next rando  q quit"

  defp help(%{status: :extension_pending}), do: "y continue  n end  q quit"
  defp help(_model), do: "q quit"

  defp mic_help(%{media: nil}), do: ""
  defp mic_help(%{model: %{connection: :connected, status: :idle}}), do: "  t mic test"
  defp mic_help(_state), do: ""

  defp mic_test_text(%{media: nil}), do: ""
  defp mic_test_text(%{mic_test: nil}), do: "\n\nPress t to test your mic (wear headphones)."

  defp mic_test_text(%{mic_test: %{error: error}}) when is_binary(error),
    do: "\n\nMic test failed: " <> error

  defp mic_test_text(%{mic_test: %{running?: true, stats: nil}}),
    do: "\n\nMic test: say something; you should hear yourself…"

  defp mic_test_text(%{mic_test: %{running?: running?, stats: stats}}) do
    prefix = if running?, do: "Mic test:", else: "Mic test done:"

    "\n\n#{prefix} ≈#{round(stats["latency_ms"])} ms delay, " <>
      "input peak #{round(stats["input_peak_dbfs"])} dBFS"
  end

  defp panel(title) do
    %Block{title: title, borders: [:all], border_type: :rounded, border_style: %Style{fg: :cyan}}
  end

  ## Helpers

  defp start_mic_test(state) do
    {input, output} = state.mic_test_endpoints

    case call_media(state.media, &Media.loopback_start(&1, input, output)) do
      {:ok, _started} ->
        Process.send_after(self(), :mic_test_done, @mic_test_ms)
        notify_test(%{state | mic_test: %{running?: true, stats: nil, error: nil}})

      {:error, reason} ->
        notify_test(%{state | mic_test: %{running?: false, stats: nil, error: reason}})
    end
  end

  defp update_mic_test(state, changes),
    do: notify_test(%{state | mic_test: Map.merge(state.mic_test, Map.new(changes))})

  # Media is optional and restartable: a missing or restarting helper is an
  # error to show, not a crash.
  defp call_media(nil, _fun), do: {:error, "no audio helper (cargo build -p randos_media)"}

  defp call_media(media, fun) do
    fun.(media)
  catch
    :exit, _reason -> {:error, "the audio helper isn't running"}
  end

  defp notify_test(state) do
    if state.test_pid, do: send(state.test_pid, {:tui_mic_test, self(), state.mic_test})
    state
  end

  defp apply_model(state, model, commands) do
    Enum.each(commands, fn {:push, event, payload} ->
      Connection.push(state.connection, event, payload)
    end)

    if state.test_pid, do: send(state.test_pid, {:tui_model, self(), model})
    %{state | model: model}
  end

  defp now_ms, do: System.system_time(:millisecond)
end
