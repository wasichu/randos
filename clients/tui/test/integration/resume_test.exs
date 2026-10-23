defmodule Tui.Integration.ResumeTest do
  @moduledoc """
  Client obligation 9 for the TUI (`docs/architecture/participant_channel.md`):
  when its connection to the server drops mid-call, it rejoins with the
  call's resume ticket and is back in the same call; its rando sees it
  reconnecting meanwhile. Against a running server (`just tui-smoke`).
  The browser side is `call_smoke.mjs`'s "obligation 9" scenario.
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

    # Drop A's websocket as the network would: shut its TCP socket down, so
    # both ends see it close (the server's channel process goes away, and
    # Slipstream reconnects).
    websocket = Tui.Connection.__connection_pid__(connection_of(a))
    {:links, links} = Process.info(websocket, :links)

    [tcp | _] =
      for port <- links, is_port(port), Port.info(port, :name) == {:name, ~c"tcp_inet"}, do: port

    :ok = :gen_tcp.shutdown(tcp, :read_write)

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
end
