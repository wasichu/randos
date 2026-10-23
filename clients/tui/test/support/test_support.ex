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
  Starts (supervised by the test) a text-only TUI against `server_url/0`;
  `opts` go to `Tui.App` (e.g. `language:`; English otherwise).
  """
  def start_app(id, size \\ {100, 24}, opts \\ []) do
    ExUnit.Callbacks.start_supervised!(
      {Tui.App, [name: nil, test_mode: size, uri: server_url(), test_pid: self()] ++ opts},
      id: id
    )
  end

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

  @repo_root Path.expand("../../../..", __DIR__)

  @doc "The repository's root (scripts and the test relay are run from there)."
  def repo_root, do: @repo_root

  @doc """
  Starts the browser half of a TUI ↔ browser call
  (`test/e2e/tui_browser_call.mjs`, headless Chrome with a fake mic) over a
  Port, against the server at `server_url/0`; it exits when the Port
  closes. `env`: the script's options (EXPECT, MIC_ERROR, RELAY_ONLY,
  REPORT_EVERY_MS).
  """
  def start_browser(speaks, hears, hold_ms, env \\ []) do
    node = System.find_executable("node") || flunk("node not found")
    %URI{host: host, port: port} = URI.parse(server_url())

    Port.open({:spawn_executable, node}, [
      :binary,
      :exit_status,
      {:line, 64_000},
      {:cd, @repo_root},
      {:env,
       Enum.map([{"BASE_URL", "http://#{host}:#{port}"} | env], fn {k, v} ->
         {String.to_charlist(k), String.to_charlist(v)}
       end)},
      args: ["test/e2e/tui_browser_call.mjs", speaks, hears, Integer.to_string(hold_ms)]
    ])
  end

  @doc """
  Waits for the app's media state (`{:tui_media, app, state}`) to satisfy
  `fun` within `timeout` ms, and returns it.
  """
  def await_media(app, fun, timeout \\ 20_000),
    do: await(:tui_media, app, fun, deadline(timeout), "media state")

  @doc "Presses keys on a running app."
  def keys(app, codes),
    do: Enum.each(codes, &Runtime.inject_event(app, %Event.Key{code: &1, kind: "press"}))

  @doc """
  Waits for the app's model (`{:tui_model, app, model}`, sent when the app
  has a `test_pid`) to satisfy `fun` within `timeout` ms, and returns it.
  """
  def await_model(app, fun, timeout \\ 20_000),
    do: await(:tui_model, app, fun, deadline(timeout), "model")

  # Against a deadline, not a timeout per message: in a call both stream
  # all the time (levels, 20 a second), so a per-message timeout never fires.
  defp await(tag, app, fun, deadline, what) do
    receive do
      {^tag, ^app, value} ->
        if fun.(value), do: value, else: await(tag, app, fun, deadline, what)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("timed out waiting for #{inspect(app)}'s #{what}")
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @doc """
  Waits for the browser script on `port` (`test/e2e/tui_browser_call.mjs`)
  to report `event` satisfying `fun`, and returns it; its `error` fails
  the test.
  """
  def await_browser(port, event, fun \\ fn _ -> true end) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode!(line) do
          %{"event" => ^event} = message ->
            if fun.(message), do: message, else: await_browser(port, event, fun)

          %{"event" => "error", "message" => message} ->
            flunk("browser: #{message}")

          _other ->
            await_browser(port, event, fun)
        end
    after
      30_000 -> flunk("timed out waiting for the browser to report #{event}")
    end
  end

  @doc """
  On a fresh idle form (`model`): speak `speaks`, hear exactly `hears` (a code
  or a list), tick 18+, press Enter.
  """
  def find(app, model, speaks, hears) do
    hears = List.wrap(hears)
    codes = Enum.map(model.languages, & &1.code)
    # A fresh form: only the speaking language is checked, automatically.
    true =
      model.hears == [model.speaks] and model.hears_cursor == 0 and not model.adult_acknowledged?

    index = fn code -> Enum.find_index(codes, &(&1 == code)) end

    to_speaks =
      List.duplicate("right", Integer.mod(index.(speaks) - index.(model.speaks), length(codes)))

    # Choosing `speaks` leaves just it checked; walk the row, toggling what differs.
    hears_row =
      codes
      |> Enum.map(fn code -> if code == speaks != code in hears, do: [" "], else: [] end)
      |> Enum.intersperse(["right"])
      |> List.flatten()

    keys(app, to_speaks ++ ["tab"] ++ hears_row ++ ["tab", " ", "enter"])
  end

  @doc "Kills a `Tui.Media` server's helper process (`kill -9`), as a crash would."
  def kill_helper(media) do
    {:os_pid, os_pid} = Port.info(:sys.get_state(media).port, :os_pid)
    System.cmd("kill", ["-9", Integer.to_string(os_pid)])
  end

  @doc "Retries `fun` while it exits (e.g. a process that's still restarting)."
  # Up to 5 s (250 × 20 ms), the tests' rule for waits (AGENTS.md).
  def eventually(fun, attempts \\ 250) do
    fun.()
  catch
    :exit, _ when attempts > 0 ->
      Process.sleep(20)
      eventually(fun, attempts - 1)
  end

  @doc "Waits until `name` is registered to a process other than `old`."
  def wait_for_restart(name, old, attempts \\ 250) do
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
