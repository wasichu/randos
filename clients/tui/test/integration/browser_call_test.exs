defmodule Tui.Integration.BrowserCallTest do
  @moduledoc """
  A real TUI (app, channel connection, and media helper with a test tone)
  calls a real headless Chrome (`test/e2e/tui_browser_call.mjs`, fake mic)
  through a running server: Stage 1's interop test. Both roles: whoever
  waits in the queue first offers. Passes when the TUI connected, sent
  `media_state` `connected`, and audio arrived both ways (the TUI's stats,
  and Chrome's own inbound-rtp energy).

  Run with `just tui-smoke` (it starts the server). Needs node, Chrome
  (`CHROME_BIN` or the usual locations), and the helper built.
  """
  use ExUnit.Case, async: false

  import Tui.TestSupport

  @moduletag :integration
  @moduletag :native
  @moduletag timeout: 120_000

  alias Tui.Model

  @hold_ms 4_000

  defp browser(speaks, listens, env \\ []),
    do: Tui.TestSupport.start_browser(speaks, listens, @hold_ms, env)

  # Until the browser's result arrives: the TUI must push
  # media_state connected and hear the browser's tone.
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
    app = start_audio_tui(:offering_tui)
    model = await_model(app, &(&1.status == :idle and &1.audio?))

    # Rarely used pairs, so nothing else on the dev server interferes.
    find(app, model, "hi", "bn")
    await_model(app, &(&1.status == :looking))

    port = browser("bn", "hi")
    assert %Model{webrtc_role: "offerer"} = await_model(app, &(&1.status == :in_call))
    assert_audio_both_ways(await_call(app, port))
  end

  test "the browser waits first and offers; the TUI answers" do
    port = browser("ar", "ru")
    await_browser(port, "looking")

    app = start_audio_tui(:answering_tui)
    model = await_model(app, &(&1.status == :idle and &1.audio?))
    find(app, model, "ru", "ar")

    assert %Model{webrtc_role: "answerer"} = await_model(app, &(&1.status == :in_call))
    assert_audio_both_ways(await_call(app, port))
  end

  ## Client obligations (docs/architecture/participant_channel.md): the same
  ## scenarios run browser-to-browser in test/e2e/call_smoke.mjs.

  defp requeued(app) do
    await_model(app, &(&1.status == :connecting))
    await_model(app, &(&1.status == :looking))
  end

  test "obligation 6: the TUI can't start audio; it ends the call with a reason, the browser is requeued" do
    app = start_audio_tui(:mute_tui, {"no-such-input", "null"})
    model = await_model(app, &(&1.status == :idle and &1.audio?))
    find(app, model, "pt", "zh")
    await_model(app, &(&1.status == :looking))

    port = browser("zh", "pt", [{"EXPECT", "call_ends"}])

    assert %Model{error: error} = await_model(app, &(&1.status == :idle and &1.error != nil))
    assert error =~ "audio isn't available"
    assert %{"looking" => true} = await_browser(port, "call_ended")
  end

  test "obligation 6: the browser's mic is denied; it ends the call with a reason, the TUI is requeued" do
    app = start_audio_tui(:denied_peer_tui)
    model = await_model(app, &(&1.status == :idle and &1.audio?))
    find(app, model, "ko", "it")
    await_model(app, &(&1.status == :looking))

    port = browser("it", "ko", [{"EXPECT", "call_ends"}, {"MIC_ERROR", "NotAllowedError"}])

    requeued(app)
    assert %{"idle" => true, "error" => error} = await_browser(port, "call_ended")
    assert error =~ "microphone"
    keys(app, ["c"])
  end

  test "obligation 4: the browser never connects; the connect timeout ends the call for both" do
    app = start_audio_tui(:stuck_peer_tui)
    model = await_model(app, &(&1.status == :idle and &1.audio?))
    find(app, model, "de", "ja")
    await_model(app, &(&1.status == :looking))

    port = browser("ja", "de", [{"EXPECT", "call_ends"}, {"RELAY_ONLY", "1"}])

    requeued(app)
    assert %{"event" => "call_ended"} = await_browser(port, "call_ended")
    keys(app, ["c"])
  end
end
