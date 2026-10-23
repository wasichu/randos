defmodule Tui.TerminalTest do
  use ExUnit.Case, async: true

  alias Tui.Terminal

  test "which terminals reorder right-to-left text, from what they set" do
    assert Terminal.bidi(%{"TERM_PROGRAM" => "Apple_Terminal"}) == :yes

    assert Terminal.bidi(%{"TERM_PROGRAM" => "iTerm.app", "TERM_PROGRAM_VERSION" => "3.7.5"}) ==
             :yes

    assert Terminal.bidi(%{"TERM_PROGRAM" => "iTerm.app", "TERM_PROGRAM_VERSION" => "3.6.2"}) ==
             :no

    assert Terminal.bidi(%{"VTE_VERSION" => "7600"}) == :yes
    assert Terminal.bidi(%{"KONSOLE_VERSION" => "230800"}) == :yes
    assert Terminal.bidi(%{"TERM_PROGRAM" => "ghostty"}) == :no
    assert Terminal.bidi(%{"WT_SESSION" => "x"}) == :no
    # tmux hides the terminal it runs in.
    assert Terminal.bidi(%{}) == :unknown
  end

  test "right-to-left languages" do
    assert Enum.all?(~w(ar fa ur), &Terminal.rtl?/1)
    refute Terminal.rtl?("es")
  end

  test "inside tmux, the terminal its client is in" do
    tmux = %{"TERM_PROGRAM" => "tmux"}
    assert Terminal.bidi(tmux, fn -> "ghostty 1.3.1|xterm-ghostty" end) == :no
    assert Terminal.bidi(tmux, fn -> "iTerm2 3.7.5|xterm-256color" end) == :yes
    assert Terminal.bidi(tmux, fn -> "|xterm-256color" end) == :unknown
    assert Terminal.bidi(tmux, fn -> nil end) == :unknown
  end
end
