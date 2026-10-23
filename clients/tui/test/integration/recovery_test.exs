defmodule Tui.Integration.RecoveryTest do
  @moduledoc """
  Client obligation 10 for the TUI (`docs/architecture/participant_channel.md`):
  a call whose media path dies comes back by ICE restart, inside the
  server's recovery budget (`Randos.Calls.Lifecycle.recovery_budget_seconds/0`),
  on the same call. Relay-only through the test relay
  (`clients/tui/native/examples/test_turn.rs`), which cuts every client's
  path, as a network change does; the clients' restarts gather from new
  sockets, so new allocations the cut doesn't cover.

  It starts its own relay and server (the server must know the relay at
  boot), so it isn't part of the plain integration run: `just tui-smoke`
  runs it with `--only recovery`. Needs the helper and the relay built
  (`just test-turn`), and node and Chrome for the browser scenarios.
  The browser ↔ browser version is `test/e2e/recovery_smoke.mjs`.
  """
  use ExUnit.Case, async: false

  import Tui.TestSupport

  @moduletag :recovery
  @moduletag :native
  @moduletag timeout: 180_000

  # Lifecycle.recovery_budget_seconds/0 (the server's; the TUI has no copy).
  @budget_ms 15_000
  # A dead path is reported within this: Chrome takes ~5.5 s, the helper
  # ~4 s (its STUN timing and the vendored ICE agent's peer-request
  # window, vendor/README.md; it was ~15 s before). Room for CI load.
  @detect_ms 10_000
  # Packets the cut can't explain: 3 s of audio (50 a second).
  @fresh 150

  setup_all do
    turn = start_turn()
    server = start_server(turn.port)
    %{turn: turn.ref, server: server}
  end

  # The test relay over a Port: it says its port first, and exits when the
  # Port closes (its stdin).
  defp start_turn do
    path = Path.join(repo_root(), "target/debug/examples/test_turn")
    File.regular?(path) || flunk("#{path} isn't built (just test-turn)")
    ref = Port.open({:spawn_executable, path}, [:binary, {:line, 1_000}])

    receive do
      {^ref, {:data, {:eol, "listening 127.0.0.1:" <> port}}} ->
        %{ref: ref, port: String.to_integer(port)}
    after
      10_000 -> flunk("test_turn didn't say its port")
    end
  end

  # A test server whose calls are relay-only through the relay. It runs
  # `cat` until the Port closes; with_test_server.sh then stops it.
  defp start_server(turn_port) do
    ice = [
      %{
        urls: "turn:127.0.0.1:#{turn_port}?transport=udp",
        username: "randos",
        credential: "randos"
      }
    ]

    script = Path.join(repo_root(), "test/e2e/with_test_server.sh")

    ref =
      Port.open({:spawn_executable, script}, [
        :binary,
        {:cd, repo_root()},
        # A long segment: the test server's default (8 s) would send the call
        # to the vote mid-test.
        {:env,
         [
           {~c"RANDOS_TEST_ICE_SERVERS", String.to_charlist(Jason.encode!(ice))},
           {~c"RANDOS_CALL_SEGMENT_MS", ~c"120000"}
         ]},
        args: ["tmp/tui-recovery-server.log", "cat"]
      ])

    %URI{port: port} = URI.parse(server_url())
    await_listening(port, 240)
    ref
  end

  defp await_listening(_port, 0), do: flunk("the test server didn't come up")

  defp await_listening(port, tries) do
    case :gen_tcp.connect(~c"localhost", port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _} ->
        Process.sleep(500)
        await_listening(port, tries - 1)
    end
  end

  defp packets(%{call: %{stats: %{"packets_received" => n}}}), do: n
  defp packets(_media), do: 0

  defp cut_all(turn), do: Port.command(turn, "cut-all\n")

  # The call goes unhealthy (`recovering`, when the server hears a side's
  # media is down: its budget starts then), then healthy again within the
  # budget, the same call, a restart having been asked for. The cut itself
  # comes first: detecting a dead path takes the clients a few seconds
  # (@detect_ms), so from the cut it's detection plus recovery.
  defp assert_recovers(app, call_id, cut_at) do
    await_model(app, &match?(%{call: %{"recovering" => true}}, &1), @detect_ms)
    unhealthy_at = System.monotonic_time(:millisecond)

    back =
      await_model(
        app,
        &match?(%{call: %{"id" => ^call_id, "recovering" => false}}, &1),
        @budget_ms
      )

    now = System.monotonic_time(:millisecond)

    assert now - unhealthy_at < @budget_ms,
           "recovered #{now - unhealthy_at} ms in, past the budget"

    assert back.status in [:in_call, :extension_pending]
    assert back.call["ice_generation"] > 0, "no restart was asked for"

    assert now - cut_at < @detect_ms + @budget_ms,
           "unhealthy #{unhealthy_at - cut_at} ms after the cut, back #{now - unhealthy_at} ms later"
  end

  defp browser_heard(%{"inbound" => %{"packetsReceived" => n}}), do: n
  defp browser_heard(_message), do: 0

  test "TUI ↔ TUI: both paths cut, the call comes back with audio both ways", %{turn: turn} do
    a = start_audio_tui(:recover_a)
    b = start_audio_tui(:recover_b)
    a_model = await_model(a, &(&1.status == :idle and &1.audio?))
    b_model = await_model(b, &(&1.status == :idle and &1.audio?))

    find(a, a_model, "bn", "hi")
    await_model(a, &(&1.status == :looking))
    find(b, b_model, "hi", "bn")
    %{call: %{"id" => call_id}} = await_model(a, &(&1.status == :in_call))
    await_model(b, &(&1.status == :in_call))

    heard_a = packets(await_media(a, &(packets(&1) > 50 and &1.relay_only?)))
    heard_b = packets(await_media(b, &(packets(&1) > 50 and &1.relay_only?)))

    cut_at = System.monotonic_time(:millisecond)
    cut_all(turn)
    assert_recovers(a, call_id, cut_at)

    await_media(a, &(packets(&1) > heard_a + @fresh), 20_000)
    await_media(b, &(packets(&1) > heard_b + @fresh), 20_000)

    keys(a, ["e"])
    await_model(a, &(&1.status == :idle))
  end

  for {name, tui_first?, pair} <- [
        {"the TUI offers, the browser answers", true, {"ja", "ko"}},
        {"the browser offers, the TUI answers", false, {"it", "tr"}}
      ] do
    @tag :browser
    test "TUI ↔ browser, #{name}: both paths cut, the call comes back", %{turn: turn} do
      {tui_speaks, browser_speaks} = unquote(pair)
      env = [{"REPORT_EVERY_MS", "500"}]

      {app, port} =
        if unquote(tui_first?) do
          app = start_audio_tui(:recover_tui)
          model = await_model(app, &(&1.status == :idle and &1.audio?))
          find(app, model, tui_speaks, browser_speaks)
          await_model(app, &(&1.status == :looking))
          {app, start_browser(browser_speaks, tui_speaks, 40_000, env)}
        else
          port = start_browser(browser_speaks, tui_speaks, 40_000, env)
          await_browser(port, "looking")
          app = start_audio_tui(:recover_tui)
          model = await_model(app, &(&1.status == :idle and &1.audio?))
          find(app, model, tui_speaks, browser_speaks)
          {app, port}
        end

      %{call: %{"id" => call_id}} = await_model(app, &(&1.status == :in_call))
      heard_tui = packets(await_media(app, &(packets(&1) > 50 and &1.relay_only?)))
      heard_browser = browser_heard(await_browser(port, "inbound", &(browser_heard(&1) > 50)))

      cut_at = System.monotonic_time(:millisecond)
      cut_all(turn)
      assert_recovers(app, call_id, cut_at)

      await_media(app, &(packets(&1) > heard_tui + @fresh), 20_000)
      await_browser(port, "inbound", &(browser_heard(&1) > heard_browser + @fresh))
    end
  end
end
