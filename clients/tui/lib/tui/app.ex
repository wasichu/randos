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
      (`s` there opens the server's status screen, `Tui.Model`'s `status_page`)
    * `:mic_test` — `{input, output}` for that test (default
      `{"device", "device"}`; tests use `{"sine", "null"}`)
    * `:config` — the settings file (`Tui.Config`): the languages, the 18+
      acknowledgment, and the devices are read from it at start and saved to
      it when they change; without one (tests), nothing is saved
    * `:test_pid` — receives `{:tui_model, app_pid, model}` after every change (tests)
  """

  use Gettext, backend: Tui.Gettext
  use ExRatatui.App

  alias ExRatatui.Event
  alias Tui.Config
  alias Tui.Connection
  alias Tui.Media
  alias Tui.Media.State, as: MediaState
  alias Tui.Model
  alias Tui.View

  require Logger

  @tick_ms 1_000
  @call_statuses Model.call_statuses()

  @impl true
  def mount(opts) do
    config = Keyword.get(opts, :config)
    saved = Config.load(config)
    language = language(opts, saved)
    Tui.Language.apply(language)

    {connection, owned?} =
      case Keyword.fetch(opts, :connection) do
        {:ok, pid} ->
          {pid, false}

        :error ->
          {:ok, pid} =
            Connection.start_link(
              uri: Keyword.fetch!(opts, :uri),
              owner: self(),
              locale: language
            )

          {pid, true}
      end

    Process.send_after(self(), :tick, @tick_ms)
    # The helper starts before us, so its first "ready" can't reach us (we
    # weren't registered yet): ask it for what "ready" would have.
    if media_running?(Keyword.get(opts, :media)), do: send(self(), :media_started)

    state = %{
      model:
        Model.new(now_ms())
        |> Model.set_audio(media_running?(Keyword.get(opts, :media)))
        |> Model.restore(saved)
        |> Map.put(:language, language),
      connection: connection,
      owned?: owned?,
      uri: Keyword.get(opts, :uri, "(test)"),
      media: Keyword.get(opts, :media),
      mic_test_endpoints: Keyword.get(opts, :mic_test, {"device", "device"}),
      media_state:
        MediaState.new(
          Keyword.get(opts, :media) != nil,
          Keyword.get(opts, :call_audio, {"device", "device"})
        )
        |> MediaState.restore_choice(saved),
      config: config,
      test_pid: Keyword.get(opts, :test_pid),
      # Whether this terminal shows right-to-left text right (a test app:
      # as told, else as if it does).
      bidi:
        Keyword.get_lazy(opts, :bidi, fn ->
          if opts[:test_mode], do: :yes, else: Tui.Terminal.bidi()
        end)
    }

    {:ok, Map.put(state, :saved, settings(state))}
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
    {model, commands} = state.model |> Model.tick(now_ms()) |> Model.refresh_status()
    {:noreply, apply_model(state, model, commands)}
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

  def handle_info(:media_started, state),
    do: {:noreply, run_media(state, MediaState.helper_started(state.media_state))}

  def handle_info({:offline_limit, drop}, state),
    do: {:noreply, run_media(state, MediaState.offline_limit(state.media_state, drop))}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_event(%Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state),
    do: {:stop, state}

  # The join prompt takes every key (a link is typed there), q included.
  def handle_event(%Event.Key{code: code, kind: "press"}, %{model: %{join_prompt: text}} = state)
      when is_binary(text) do
    {model, commands} = Model.key(state.model, code)
    {:noreply, apply_model(state, model, commands)}
  end

  def handle_event(%Event.Paste{content: text}, state) do
    {model, commands} = Model.paste(state.model, text)
    {:noreply, apply_model(state, model, commands)}
  end

  def handle_event(%Event.Key{code: "q", kind: "press"}, state), do: {:stop, state}

  def handle_event(
        %Event.Key{code: "t", kind: "press"},
        %{model: %{connection: :connected, status: :idle, status_page: nil}} = state
      ) do
    step = MediaState.toggle_mic_test(state.media_state, state.mic_test_endpoints)
    {:noreply, run_media(state, step)}
  end

  # Choose the mic (i) and speaker (o) on the idle screen.
  def handle_event(
        %Event.Key{code: code, kind: "press"},
        %{model: %{connection: :connected, status: :idle, status_page: nil}} = state
      )
      when code in ["i", "o"] do
    which = if code == "i", do: :input, else: :output
    state = %{state | media_state: MediaState.cycle_device(state.media_state, which)}
    {:noreply, persist(state)}
  end

  def handle_event(
        %Event.Key{code: "m", kind: "press"},
        %{model: %{status: status, audio?: true}} = state
      )
      when status in @call_statuses do
    {:noreply, run_media(state, MediaState.toggle_mute(state.media_state))}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state) do
    {model, commands} = Model.key(state.model, code)
    {:noreply, state |> apply_model(model, commands) |> persist()}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Quitting mid-call is leaving on purpose: say so (as the browser does on
    # page hide), so the call ends `peer_disconnected` rather than looking
    # like a lost connection.
    if state.model.status in @call_statuses,
      do: Connection.leave(state.connection)

    # Closing the channel ends our participant: the server takes us out of
    # the queue and ends any call.
    if state.owned?, do: GenServer.stop(state.connection)
  end

  ## Rendering

  @impl true
  def render(state, frame), do: View.render(state, frame)

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
        {:error,
         gettext("the audio helper isn't running (is it built? %{command})",
           command: "cargo build -p randos_media"
         )}

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
  defp follow_call(state, {:joined, %{"resumed" => true}}) do
    state = run_media(state, MediaState.online(state.media_state))
    state = run_media(state, server_state(state))
    run_media(state, MediaState.resumed(state.media_state))
  end

  defp follow_call(state, {:joined, _reply}) do
    state = run_media(state, MediaState.online(state.media_state))
    run_media(state, server_state(state))
  end

  defp follow_call(state, {:push, "state", _}), do: run_media(state, server_state(state))

  defp follow_call(state, :disconnected) do
    state = run_media(state, server_state(state))
    run_media(state, MediaState.offline(state.media_state))
  end

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

    if model.language != state.model.language do
      Tui.Language.apply(model.language)
      Connection.set_locale(state.connection, model.language)
    end

    # The screen shows only the latest notice; the full history goes to the
    # log file (`tmp/tui.log`), for debugging a call afterwards.
    with [line | _] when model.log != state.model.log <- model.log do
      Logger.info("tui: " <> line)
    end

    if state.test_pid, do: send(state.test_pid, {:tui_model, self(), model})
    %{state | model: model}
  end

  # Saves the settings file when what it keeps has changed.
  defp persist(state) do
    case settings(state) do
      same when same == state.saved ->
        state

      settings ->
        Config.save(state.config, settings)
        %{state | saved: settings}
    end
  end

  defp settings(state),
    do: Map.merge(Model.saved(state.model), MediaState.saved_choice(state.media_state))

  # `:language` (tests pass one); a test app (`test_mode`) without one is in
  # English whatever the machine's LANG, since tests read the screen's text.
  defp language(opts, saved) do
    cond do
      language = opts[:language] -> language
      opts[:test_mode] -> "en"
      true -> Tui.Language.resolve(saved["language"])
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
