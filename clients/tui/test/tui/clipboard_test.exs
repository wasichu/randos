defmodule Tui.ClipboardTest do
  @moduledoc """
  Which way a copy goes (`Tui.Clipboard`); the copy itself never runs in
  tests (they use `Tui.TestSupport.Clipboard`), so the real clipboard is
  never touched.
  """
  use ExUnit.Case, async: true

  alias Tui.Clipboard

  test "the system's command where there is one, else the terminal (OSC 52)" do
    case :os.type() do
      {:unix, :darwin} ->
        assert {exe, []} = Clipboard.command(%{})
        assert Path.basename(exe) == "pbcopy"

      {:unix, _linux} ->
        # No display: neither Wayland's nor X's tools can copy; the terminal is asked.
        assert Clipboard.command(%{"WAYLAND_DISPLAY" => "", "DISPLAY" => nil}) == nil
    end
  end

  test "over SSH the terminal is asked, never a command on the far machine" do
    assert Clipboard.command(%{"SSH_TTY" => "/dev/ttys001"}) == nil
    assert Clipboard.command(%{"SSH_CONNECTION" => "1.2.3.4 5 6.7.8.9 22"}) == nil
  end
end
