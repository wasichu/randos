defmodule Tui.Integration.BrowserCallTest do
  @moduledoc """
  A real TUI (app, channel connection, and media helper with a test tone)
  calls a real headless Chrome (`test/e2e/tui_browser_call.mjs`, fake mic)
  through a running server: Stage 1's interop test. Both roles: whoever
  waits in the queue first offers. Passes when the TUI connected, sent
  `connection_established`, and audio arrived both ways (the TUI's stats,
  and Chrome's own inbound-rtp energy).

  Run with `just tui-smoke` (it starts the server). Needs node, Chrome
  (`CHROME_BIN` or the usual locations), and the helper built.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :native
  @moduletag timeout: 120_000

  alias ExRatatui.Event
  alias ExRatatui.Runtime
  alias Tui.Model

  @repo_root Path.expand("../../../..", __DIR__)
  @hold_ms 4_000

  defp ws_url, do: System.get_env("RANDOS_URL") || "ws://localhost:4010/participant/websocket"

  defp base_url do
    %URI{host: host, port: port} = URI.parse(ws_url())
    "http://#{host}:#{port}"
  end

  # A TUI with a helper playing a test tone and discarding what it hears.
  defp start_tui(id) do
    media = :"#{id}_media"

    app =
      start_supervised!(
        {Tui.App,
         name: nil,
         test_mode: {100, 24},
         uri: ws_url(),
         test_pid: self(),
         media: media,
         call_audio: {"sine", "null"}},
        id: id
      )

    start_supervised!({Tui.Media, name: media, notify: app}, id: media)
    app
  end

  defp start_browser(speaks, listens) do
    node = System.find_executable("node") || flunk("node not found")

    Port.open({:spawn_executable, node}, [
      :binary,
      :exit_status,
      {:line, 64_000},
      {:cd, @repo_root},
      {:env, [{~c"BASE_URL", String.to_charlist(base_url())}]},
      args: ["test/e2e/tui_browser_call.mjs", speaks, listens, Integer.to_string(@hold_ms)]
    ])
  end

  defp keys(pid, codes),
    do: Enum.each(codes, &Runtime.inject_event(pid, %Event.Key{code: &1, kind: "press"}))

  defp await_model(pid, fun) do
    receive do
      {:tui_model, ^pid, model} -> if fun.(model), do: model, else: await_model(pid, fun)
    after
      20_000 -> flunk("timed out waiting for the TUI's model")
    end
  end

  defp await_browser(port, event) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode!(line) do
          %{"event" => ^event} = message -> message
          %{"event" => "error", "message" => message} -> flunk("browser: #{message}")
          _other -> await_browser(port, event)
        end
    after
      30_000 -> flunk("timed out waiting for the browser to report #{event}")
    end
  end

  # Pick the pair on the TUI's form, tick 18+, and press Enter.
  defp find(pid, model, speaks, listens) do
    index = fn code -> Enum.find_index(model.languages, &(&1.code == code)) end

    move = fn from, to ->
      List.duplicate("right", Integer.mod(to - from, length(model.languages)))
    end

    keys(
      pid,
      move.(model.speaks, index.(speaks)) ++
        ["tab"] ++ move.(model.listens, index.(listens)) ++ ["tab", " ", "enter"]
    )
  end

  # Until the browser's result arrives: the TUI must push
  # connection_established and hear the browser's tone.
  defp await_call(app, port, seen \\ %{connected?: false, heard?: false}) do
    receive do
      {:tui_media, ^app, %{call: %{connection: :connected, stats: stats}}} when is_map(stats) ->
        heard? = stats["packets_received"] > 50 and stats["output_peak_dbfs"] > -50
        await_call(app, port, %{seen | connected?: true, heard?: seen.heard? or heard?})

      {:tui_media, ^app, %{call: %{connection: :connected}}} ->
        await_call(app, port, %{seen | connected?: true})

      {^port, {:data, {:eol, line}}} ->
        case Jason.decode!(line) do
          %{"event" => "result", "inbound" => inbound} -> Map.put(seen, :browser_inbound, inbound)
          %{"event" => "error", "message" => message} -> flunk("browser: #{message}")
          _other -> await_call(app, port, seen)
        end
    after
      @hold_ms + 30_000 -> flunk("call didn't finish: #{inspect(seen)}")
    end
  end

  defp assert_audio_both_ways(result) do
    assert result.connected?, "the TUI's helper never connected"
    assert result.heard?, "the TUI never heard the browser's mic"

    inbound = result.browser_inbound || flunk("Chrome had no inbound audio stream")

    assert inbound["packetsReceived"] > 50,
           "Chrome received #{inbound["packetsReceived"]} packets"

    assert inbound["totalAudioEnergy"] > 0.01, "Chrome heard silence: #{inspect(inbound)}"
  end

  test "the TUI waits first and offers; the browser answers" do
    app = start_tui(:offering_tui)
    model = await_model(app, &(&1.status == :idle and &1.audio?))

    # Rarely used pairs, so nothing else on the dev server interferes.
    find(app, model, "hi", "bn")
    await_model(app, &(&1.status == :looking))

    port = start_browser("bn", "hi")
    assert %Model{webrtc_role: "offerer"} = await_model(app, &(&1.status == :in_call))
    assert_audio_both_ways(await_call(app, port))
  end

  test "the browser waits first and offers; the TUI answers" do
    port = start_browser("ar", "ru")
    await_browser(port, "looking")

    app = start_tui(:answering_tui)
    model = await_model(app, &(&1.status == :idle and &1.audio?))
    find(app, model, "ru", "ar")

    assert %Model{webrtc_role: "answerer"} = await_model(app, &(&1.status == :in_call))
    assert_audio_both_ways(await_call(app, port))
  end
end
