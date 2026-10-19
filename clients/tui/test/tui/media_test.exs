defmodule Tui.MediaTest do
  use ExUnit.Case, async: true

  alias Tui.Media

  # Needs the helper built (`cargo build -p randos_media`; `just precommit`
  # does this before the TUI tests). Excluded otherwise; see test_helper.exs.
  @moduletag :native

  test "round-trips a ping through the real helper over the Port" do
    media = start_supervised!({Media, []})
    assert Media.ping(media) == :pong
    assert Media.ping(media) == :pong
  end

  @tag :capture_log
  test "the helper exiting stops the owner, so a supervisor can react" do
    media = start_supervised!({Media, []}, restart: :temporary)
    ref = Process.monitor(media)
    {:os_pid, os_pid} = Port.info(:sys.get_state(media).port, :os_pid)

    System.cmd("kill", ["-9", Integer.to_string(os_pid)])

    assert_receive {:DOWN, ^ref, :process, ^media, {:helper_exited, _status}}, 2_000
  end

  test "a missing helper binary is a clear startup error" do
    Process.flag(:trap_exit, true)

    assert {:error, {:helper_not_found, "/nonexistent/randos_media"}} =
             Media.start_link(helper_path: "/nonexistent/randos_media")
  end
end
