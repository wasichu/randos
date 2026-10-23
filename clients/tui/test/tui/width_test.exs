defmodule Tui.WidthTest do
  use ExUnit.Case, async: true

  alias Tui.Width

  test "wide characters take two cells, non-spacing marks none" do
    assert Width.of("Now:") == 4
    assert Width.of("现在：") == 6
    assert Width.of("지금") == 4
    # Hindi: क + ि (spacing, one cell) and ं (non-spacing, none).
    assert Width.of("कि") == 2
    assert Width.of("कं") == 1
  end

  test "pad and fit count cells" do
    assert Width.pad("现在", 6) == "现在  "
    assert Width.fit("现在连接", 5) == "现在…"
    assert Width.fit("short", 10) == "short"
  end
end
