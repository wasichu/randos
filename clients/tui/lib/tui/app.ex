defmodule Tui.App do
  @moduledoc """
  The terminal UI (an ex_ratatui callback-runtime app): a shell over two pure
  models, `Tui.Model` (the participant channel) and `Tui.Media.State` (local
  audio). It maps events to them and runs the commands they return.

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
  alias Tui.Media.State, as: MediaState
  alias Tui.Model

  require Logger

  @tick_ms 1_000

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
       model: Model.set_audio(Model.new(now_ms()), media_running?(Keyword.get(opts, :media))),
       connection: connection,
       owned?: owned?,
       uri: Keyword.get(opts, :uri, "(test)"),
       media: Keyword.get(opts, :media),
       mic_test_endpoints: Keyword.get(opts, :mic_test, {"device", "device"}),
       media_state:
         MediaState.new(
           Keyword.get(opts, :media) != nil,
           Keyword.get(opts, :call_audio, {"device", "device"})
         ),
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

    state = apply_model(state, model, commands)
    {:noreply, follow_call(state, message)}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, apply_model(state, Model.tick(state.model, now_ms()), [])}
  end

  def handle_info({:media, name, payload}, state) do
    # A (re)started helper can carry calls again.
    state =
      if name == "ready",
        do: apply_model(state, Model.set_audio(state.model, true), []),
        else: state

    {:noreply, run_media(state, MediaState.event(state.media_state, name, payload))}
  end

  def handle_info({:media_reply, command, result}, state),
    do: {:noreply, run_media(state, MediaState.reply(state.media_state, command, result))}

  def handle_info(:mic_test_done, state),
    do: {:noreply, run_media(state, MediaState.mic_test_done(state.media_state))}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_event(%Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state),
    do: {:stop, state}

  def handle_event(%Event.Key{code: "q", kind: "press"}, state), do: {:stop, state}

  def handle_event(
        %Event.Key{code: "t", kind: "press"},
        %{model: %{connection: :connected, status: :idle}} = state
      ) do
    step = MediaState.start_mic_test(state.media_state, state.mic_test_endpoints)
    {:noreply, run_media(state, step)}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state) do
    {model, commands} = Model.key(state.model, code)
    {:noreply, apply_model(state, model, commands)}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Quitting mid-call is leaving on purpose: say so (as the browser does on
    # page hide), so the call ends `peer_disconnected` rather than looking
    # like a lost connection.
    if state.model.status in [:connecting, :in_call, :extension_pending],
      do: Connection.leave(state.connection)

    # Closing the channel ends our participant: the server takes us out of
    # the queue and ends any call.
    if state.owned?, do: GenServer.stop(state.connection)
  end

  ## Rendering

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header_area, main_area, status_area, help_area] =
      Layout.split(area, :vertical, [{:length, 3}, {:min, 8}, {:length, 5}, {:length, 1}])

    model = state.model

    [
      {header(state), header_area}
      | main(model, main_area, extra_text(state))
    ] ++
      [
        {%Paragraph{text: status_text(state), block: panel(" Status "), wrap: true}, status_area},
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

  defp main(model, area, extra) do
    [{%Paragraph{text: main_text(model) <> extra, block: panel(title(model)), wrap: true}, area}]
  end

  defp header(%{model: model, uri: uri}) do
    connection = if model.connection == :connected, do: "connected", else: "connecting…"

    %Paragraph{
      text:
        "#{if model.audio?, do: "Audio on", else: "Text only (no audio helper)"}.  #{connection} to #{uri}",
      block: panel(" randos ")
    }
  end

  defp title(%{connection: :connecting}), do: " Connecting "
  defp title(%{status: :idle}), do: " Find a rando "
  defp title(%{status: :looking}), do: " Looking "
  defp title(%{status: :connecting}), do: " Matched "
  defp title(%{status: :in_call}), do: " In call "
  defp title(%{status: :extension_pending}), do: " Time is up "
  defp title(_model), do: " randos "

  defp main_text(%{connection: :connecting}), do: "Connecting to the server…"

  defp main_text(%{status: :looking} = model) do
    "Looking for a rando who speaks #{Model.language_name(model, :listens)} " <>
      "and wants to hear #{Model.language_name(model, :speaks)}…"
  end

  defp main_text(%{status: :connecting}), do: "Matched! Starting the call…"

  defp main_text(%{status: :in_call, audio?: true} = model),
    do: "You're in a call.#{time_left(model, " remaining")}"

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

  defp mic_help(%{media_state: %{available?: false}}), do: ""
  defp mic_help(%{model: %{connection: :connected, status: :idle}}), do: "  t mic test"
  defp mic_help(_state), do: ""

  defp extra_text(%{model: %{status: :idle}} = state), do: mic_test_text(state)
  defp extra_text(_state), do: ""

  # The current state at a glance, like the website's status label and its
  # "Connection:" line, plus the latest notice (full history: tmp/tui.log).
  defp status_text(%{model: model} = state) do
    [
      "Status:     " <> status_label(model),
      "Connection: " <> connection_line(state),
      "Last:       " <> (Elixir.List.first(model.log) || "—")
    ]
    |> Enum.join("\n")
  end

  defp status_label(%{connection: :connecting}), do: "connecting to the server…"
  defp status_label(%{status: :idle}), do: "not looking"
  defp status_label(%{status: :looking}), do: "looking for a rando"
  defp status_label(%{status: :connecting}), do: "matched, preparing the call"
  defp status_label(%{status: :in_call}), do: "in a call"
  defp status_label(%{status: :extension_pending}), do: "time is up: continue?"
  defp status_label(_model), do: "—"

  defp connection_line(%{model: %{status: status, audio?: true}} = state)
       when status in [:connecting, :in_call, :extension_pending],
       do: call_line(state.media_state)

  defp connection_line(%{model: %{status: status}})
       when status in [:connecting, :in_call, :extension_pending],
       do: "text only (no audio)"

  defp connection_line(_state), do: "no call"

  defp call_line(%{call: nil, last_call_error: error}) when is_binary(error), do: error
  defp call_line(%{call: nil}), do: "starting audio…"
  defp call_line(%{call: %{connection: :disconnected}}), do: "reconnecting…"
  defp call_line(%{call: %{connection: :failed}}), do: "failed"
  defp call_line(%{call: %{connection: :connecting}}), do: "connecting…"

  defp call_line(%{call: %{stats: %{} = s}}) do
    "connected · you #{round(s["input_peak_dbfs"])} dBFS · " <>
      "peer #{round(s["output_peak_dbfs"])} dBFS · " <>
      "#{s["packets_sent"]} sent / #{s["packets_received"]} received"
  end

  defp call_line(%{call: %{}}), do: "connected"

  defp mic_test_text(%{media_state: %{available?: false}}), do: ""
  defp mic_test_text(%{media_state: %{mic_test: test}}), do: "\n\n" <> mic_test_line(test)

  defp mic_test_line(nil), do: "Press t to test your mic (wear headphones)."
  defp mic_test_line(%{phase: :failed, error: error}), do: "Mic test failed: " <> error

  defp mic_test_line(%{phase: phase, stats: nil}) when phase in [:starting, :running],
    do: "Mic test: say something; you should hear yourself…"

  defp mic_test_line(%{phase: :done, stats: nil}), do: "Mic test done."

  defp mic_test_line(%{phase: phase, stats: stats}) do
    prefix = if phase == :done, do: "Mic test done:", else: "Mic test:"

    "#{prefix} ≈#{round(stats["latency_ms"])} ms delay, " <>
      "input peak #{round(stats["input_peak_dbfs"])} dBFS"
  end

  defp panel(title) do
    %Block{title: title, borders: [:all], border_type: :rounded, border_style: %Style{fg: :cyan}}
  end

  ## Helpers

  defp run_media(state, {media_state, commands}) do
    Enum.reduce(commands, put_media_state(state, media_state), &run_media_command/2)
  end

  # Media is optional and restartable. A request to a helper that isn't
  # running is answered here as an error, so nothing waits on a dead process.
  defp run_media_command({:request, command}, state) do
    if state.media && GenServer.whereis(state.media) do
      Media.request_async(state.media, command)
      state
    else
      reply =
        {:error, "the audio helper isn't running (is it built? cargo build -p randos_media)"}

      run_media(state, MediaState.reply(state.media_state, command, reply))
    end
  end

  defp run_media_command({:push, event, payload}, state) do
    Connection.push(state.connection, event, payload)
    state
  end

  defp run_media_command({:after, ms, message}, state) do
    Process.send_after(self(), message, ms)
    state
  end

  # Server messages that matter to call audio, after the model has them.
  defp follow_call(state, {:joined, _reply}), do: run_media(state, server_state(state))
  defp follow_call(state, {:push, "state", _}), do: run_media(state, server_state(state))
  defp follow_call(state, :disconnected), do: run_media(state, server_state(state))

  defp follow_call(
         %{model: %{audio?: true}} = state,
         {:push, "signal", %{"type" => type} = signal}
       ),
       do:
         run_media(
           state,
           MediaState.remote_signal(state.media_state, type, signal["payload"] || %{})
         )

  defp follow_call(state, _message), do: state

  defp server_state(%{model: model} = state),
    do: MediaState.server_state(state.media_state, model.status, model.webrtc_role, model.call)

  defp media_running?(nil), do: false
  defp media_running?(media), do: GenServer.whereis(media) != nil

  defp put_media_state(state, media_state) do
    if state.test_pid, do: send(state.test_pid, {:tui_media, self(), media_state})
    %{state | media_state: media_state}
  end

  defp apply_model(state, model, commands) do
    Enum.each(commands, fn {:push, event, payload} ->
      Connection.push(state.connection, event, payload)
    end)

    # The screen shows only the latest notice; the full history goes to the
    # log file (`tmp/tui.log`), for debugging a call afterwards.
    with [line | _] when model.log != state.model.log <- model.log do
      Logger.info("tui: " <> line)
    end

    if state.test_pid, do: send(state.test_pid, {:tui_model, self(), model})
    %{state | model: model}
  end

  defp now_ms, do: System.system_time(:millisecond)
end
