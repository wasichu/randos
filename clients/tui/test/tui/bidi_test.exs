defmodule Tui.BidiTest do
  use ExUnit.Case, async: true

  alias Tui.Bidi

  test "right-to-left runs read right to left; left-to-right text stays put" do
    assert Bidi.visual("rando الخاص بك") == "rando كب صاخلا"
    assert Bidi.visual("No Arabic here: 4:59") == "No Arabic here: 4:59"
  end

  test "numbers inside right-to-left text keep their own order, separators included" do
    assert Bidi.visual("الآن: 4:59 متبقية") == "ةيقبتم 4:59 :نآلا"
    assert Bidi.visual("مكالمات: ١٢") == "١٢ :تاملاكم"
  end

  test "each key hint keeps its place; its words read right to left" do
    assert Bidi.visual("q خروج  t اختبار الميكروفون") == "q جورخ  t نوفوركيملا رابتخا"
  end

  test "brackets in right-to-left text are mirrored" do
    assert Bidi.visual("لغة (عربي)") == "(يبرع) ةغل"
  end

  test "wrap breaks by words into lines of a width, keeping blank lines" do
    assert Bidi.wrap("one two three four", 9) == ["one two", "three", "four"]
    assert Bidi.wrap("a\n\nb", 10) == ["a", "", "b"]
  end
end
