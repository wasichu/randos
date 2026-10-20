defmodule Tui.SupervisorTest do
  # Uses the tree's real registered names (Tui.App, Tui.Media): not async.
  use ExUnit.Case, async: false

  import Tui.TestSupport

  @moduletag :native
  @moduletag :capture_log

  test "boots the app with media, and a helper crash restarts only media" do
    start_supervised!(
      {Tui.Supervisor, uri: "ws://test.invalid", app: [test_mode: {80, 24}, connection: self()]}
    )

    app = Process.whereis(Tui.App)
    media = Process.whereis(Tui.Media)
    assert Tui.Media.ping(Tui.Media) == :pong

    ref = Process.monitor(media)
    kill_helper(media)
    assert_receive {:DOWN, ^ref, :process, ^media, {:helper_exited, _}}, 2_000

    assert eventually(fn -> Tui.Media.ping(Tui.Media) == :pong end)
    assert Process.whereis(Tui.App) == app, "the UI (and its call channel) survived"
  end
end
