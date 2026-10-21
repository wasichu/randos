defmodule Tui.TestSupport do
  @moduledoc """
  Helpers shared by the TUI's tests: driving a running `Tui.App` like a
  person (keys, the language form), waiting on its model, and killing or
  waiting on the media helper.
  """
  import ExUnit.Assertions, only: [flunk: 1]

  alias ExRatatui.Event
  alias ExRatatui.Runtime

  @doc "The server the integration tests use (`RANDOS_URL`; `just tui-smoke` sets it)."
  def server_url, do: System.get_env("RANDOS_URL") || "ws://localhost:4010/participant/websocket"

  @doc """
  Starts (supervised by the test) a TUI against `server_url/0` with its own
  media helper, which plays `audio` (`{input, output}`; default a test tone
  into nothing, so tests never make a sound).
  """
  def start_audio_tui(id, audio \\ {"sine", "null"}) do
    media = :"#{id}_media"

    app =
      ExUnit.Callbacks.start_supervised!(
        {Tui.App,
         name: nil,
         test_mode: {100, 24},
         uri: server_url(),
         test_pid: self(),
         media: media,
         call_audio: audio},
        id: id
      )

    ExUnit.Callbacks.start_supervised!({Tui.Media, name: media, notify: app}, id: media)
    app
  end

  @doc "Presses keys on a running app."
  def keys(app, codes),
    do: Enum.each(codes, &Runtime.inject_event(app, %Event.Key{code: &1, kind: "press"}))

  @doc """
  Waits for the app's model (`{:tui_model, app, model}`, sent when the app
  has a `test_pid`) to satisfy `fun`, and returns it.
  """
  def await_model(app, fun, timeout \\ 20_000) do
    receive do
      {:tui_model, ^app, model} ->
        if fun.(model), do: model, else: await_model(app, fun, timeout)
    after
      timeout -> flunk("timed out waiting for #{inspect(app)}'s model")
    end
  end

  @doc "On the idle form (`model`): pick the languages, tick 18+, press Enter."
  def find(app, model, speaks, listens) do
    index = fn code -> Enum.find_index(model.languages, &(&1.code == code)) end

    move = fn from, to ->
      List.duplicate("right", Integer.mod(to - from, length(model.languages)))
    end

    keys(
      app,
      move.(model.speaks, index.(speaks)) ++
        ["tab"] ++ move.(model.listens, index.(listens)) ++ ["tab", " ", "enter"]
    )
  end

  @doc "Kills a `Tui.Media` server's helper process (`kill -9`), as a crash would."
  def kill_helper(media) do
    {:os_pid, os_pid} = Port.info(:sys.get_state(media).port, :os_pid)
    System.cmd("kill", ["-9", Integer.to_string(os_pid)])
  end

  @doc "Retries `fun` while it exits (e.g. a process that's still restarting)."
  def eventually(fun, attempts \\ 50) do
    fun.()
  catch
    :exit, _ when attempts > 0 ->
      Process.sleep(20)
      eventually(fun, attempts - 1)
  end

  @doc "Waits until `name` is registered to a process other than `old`."
  def wait_for_restart(name, old, attempts \\ 50) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when attempts > 0 ->
        Process.sleep(20)
        wait_for_restart(name, old, attempts - 1)

      _ ->
        flunk("#{inspect(name)} didn't restart")
    end
  end
end
