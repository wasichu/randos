defmodule Tui.Integration.StatusTest do
  @moduledoc """
  The server status screen against a running server (RANDOS_URL; `just
  tui-smoke` starts one): `s` on the idle screen asks for the channel's
  `status` and shows the reply (the same data as the website's /status).
  """
  use ExUnit.Case, async: false

  import Tui.TestSupport

  @moduletag :integration
  @moduletag timeout: 30_000

  test "s opens the status screen with the server's status; esc goes back" do
    app = start_app(:app, {100, 30})

    await_model(app, &(&1.status == :idle))
    keys(app, ["s"])

    %{status_page: %{snapshot: snapshot}} =
      await_model(app, &match?(%{status_page: %{snapshot: %{}}}, &1))

    # The throwaway server has no TURN server; its counts are today's.
    assert %{"relay" => %{"state" => "not_configured"}, "usage" => usage} = snapshot
    assert %{"date" => _, "since" => _, "calls_started" => started} = usage
    assert is_integer(started)

    keys(app, ["esc"])
    assert %{status_page: nil} = await_model(app, &(&1.status_page == nil))
  end
end
