defmodule Tui.Integration.ResumeTest do
  @moduledoc """
  Client obligation 9 for the TUI (`docs/architecture/participant_channel.md`):
  when its connection to the server drops mid-call, it rejoins with the
  call's resume ticket and is back in the same call; its rando sees it
  reconnecting meanwhile. Against a running server (`just tui-smoke`).
  The browser side is `call_smoke.mjs`'s "obligation 9" scenario.
  With audio, the call's media keeps going through the drop and after it,
  on the same helper session.
  """
  use ExUnit.Case, async: false

  import Tui.TestSupport

  @moduletag :integration
  @moduletag timeout: 60_000

  # The app's own Tui.Connection (it starts and links it).
  defp connection_of(app) do
    {:links, links} = Process.info(app, :links)

    Enum.find(links, fn pid ->
      with true <- is_pid(pid),
           {:dictionary, dictionary} <- Process.info(pid, :dictionary) do
        dictionary[:"$initial_call"] == {Tui.Connection, :init, 1}
      else
        _not_it -> false
      end
    end) || flunk("no Tui.Connection linked to the app")
  end

  # Drops the app's websocket as the network would: shuts its TCP socket
  # down, so both ends see it close (the server's channel process goes
  # away, and Slipstream reconnects).
  defp drop_websocket(app) do
    websocket = Tui.Connection.__connection_pid__(connection_of(app))
    {:links, links} = Process.info(websocket, :links)

    [tcp | _] =
      for port <- links, is_port(port), Port.info(port, :name) == {:name, ~c"tcp_inet"}, do: port

    :ok = :gen_tcp.shutdown(tcp, :read_write)
  end

  defp packets(%{call: %{stats: %{"packets_received" => n}}}), do: n
  defp packets(_media), do: 0

  test "a dropped connection rejoins with its ticket and is back in the call" do
    a = start_app(:resume_a)
    b = start_app(:resume_b)
    a_model = await_model(a, &(&1.status == :idle))
    b_model = await_model(b, &(&1.status == :idle))

    # A rarely used pair, so nothing else on the server interferes.
    find(a, a_model, "bn", "hi")
    await_model(a, &(&1.status == :looking))
    find(b, b_model, "hi", "bn")

    %{call: %{"id" => call_id}} = await_model(a, &(&1.status == :in_call))
    await_model(b, &(&1.status == :in_call))

    drop_websocket(a)

    # B sees its rando reconnecting; A comes back into the same call.
    await_model(b, &match?(%{call: %{"peer_reconnecting" => true}}, &1))

    back =
      await_model(a, &(&1.connection == :connected and match?(%{call: %{"id" => ^call_id}}, &1)))

    assert back.status == :in_call
    await_model(b, &match?(%{call: %{"id" => ^call_id, "peer_reconnecting" => false}}, &1))

    # Still in the call together: ending it from A ends it for B.
    keys(a, ["e"])
    await_model(a, &(&1.status == :idle))
    await_model(b, &(&1.status in [:looking, :idle]))
  end

  for {label, masked?} <- [{"audio", false}, {"masked audio", true}] do
    test "with #{label}: media keeps going through the drop, on the same session" do
      assert_audio_resume(unquote(masked?))
    end
  end

  defp assert_audio_resume(masked?) do
    a = start_audio_tui(:resume_audio_a)
    b = start_audio_tui(:resume_audio_b)
    a_model = await_model(a, &(&1.status == :idle and &1.audio?))
    b_model = await_model(b, &(&1.status == :idle and &1.audio?))

    if masked? do
      keys(a, ["b", "2", "esc"])
      keys(b, ["b", "3", "right", "esc"])
      await_media(a, &(&1.voice_family == "tone"))
      await_media(b, &(&1.voice_family == "tone_pitch" and &1.voice_tone == "brighter"))
    end

    find(a, a_model, "fa", "ur")
    await_model(a, &(&1.status == :looking))
    find(b, b_model, "ur", "fa")

    %{call: %{"id" => call_id}} = await_model(a, &(&1.status == :in_call))
    await_model(b, &(&1.status == :in_call))
    %{call: %{seq: session}} = a_media = await_media(a, &(packets(&1) > 50))
    b_media = await_media(b, &(packets(&1) > 50))
    heard = packets(b_media)

    for media <- [a_media, b_media] do
      assert media.call.stats["output_peak_dbfs"] > -50, "peer audio was silent"
    end

    if masked? do
      assert a_media.call.masking == "lower_resonance"
      assert b_media.call.masking == "higher_resonance_pitch"
    end

    drop_websocket(a)
    await_model(b, &match?(%{call: %{"peer_reconnecting" => true}}, &1))
    # A's audio doesn't need the server: B goes on hearing it meanwhile.
    heard = packets(await_media(b, &(packets(&1) > heard + 25)))

    await_model(a, &(&1.connection == :connected and match?(%{call: %{"id" => ^call_id}}, &1)))
    await_model(b, &match?(%{call: %{"id" => ^call_id, "peer_reconnecting" => false}}, &1))

    # The same helper session (no new call_start), and audio both ways.
    %{call: %{seq: ^session}} = media = await_media(a, &(packets(&1) > 0))
    await_media(a, &(packets(&1) > packets(media) + 25))
    await_media(b, &(packets(&1) > heard + 25))

    keys(a, ["e"])
    await_model(a, &(&1.status == :idle))
  end
end
