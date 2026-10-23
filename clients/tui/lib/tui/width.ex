defmodule Tui.Width do
  @moduledoc """
  How many terminal cells a text takes, as ratatui counts them
  (unicode-width): East Asian wide and fullwidth characters take two,
  combining marks and zero-width characters none, the rest one. For
  lining up translated labels and cutting lines to fit; `String.length/1`
  counts characters, which is wrong for Chinese, Japanese and Korean.
  """

  # Wide: CJK, Hangul, kana, fullwidth forms (the ranges unicode-width
  # treats as wide that our languages use).
  @wide [
    0x1100..0x115F,
    0x2E80..0x303E,
    0x3041..0x33FF,
    0x3400..0x4DBF,
    0x4E00..0x9FFF,
    0xA000..0xA4CF,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE30..0xFE4F,
    0xFF00..0xFF60,
    0xFFE0..0xFFE6,
    0x20000..0x3FFFD
  ]

  @doc "The cells `text` takes."
  @spec of(String.t()) :: non_neg_integer()
  def of(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, sum -> sum + char_width(char) end)
  end

  @doc "`text` padded with spaces to `cells`."
  @spec pad(String.t(), non_neg_integer()) :: String.t()
  def pad(text, cells), do: text <> String.duplicate(" ", max(cells - of(text), 0))

  @doc "`text` cut to `cells`, ending in \"…\" when it was cut."
  @spec fit(String.t(), non_neg_integer()) :: String.t()
  def fit(text, cells) do
    if of(text) <= cells,
      do: text,
      else: take(String.graphemes(text), max(cells - 1, 0), "") <> "…"
  end

  defp take([], _room, acc), do: acc

  defp take([grapheme | rest], room, acc) do
    width = of(grapheme)
    if width > room, do: acc, else: take(rest, room - width, acc <> grapheme)
  end

  # Non-spacing marks (Arabic harakat, Devanagari and Bengali signs that sit
  # above or below, Vietnamese tones when decomposed) and zero-width
  # characters take no cell; spacing vowel signs (ा) take one.
  @zero [
    0x0300..0x036F,
    0x0610..0x061A,
    0x064B..0x065F,
    0x0670..0x0670,
    0x06D6..0x06ED,
    0x0900..0x0902,
    0x093A..0x093A,
    0x093C..0x093C,
    0x0941..0x0948,
    0x094D..0x094D,
    0x0951..0x0957,
    0x0962..0x0963,
    0x0981..0x0981,
    0x09BC..0x09BC,
    0x09C1..0x09C4,
    0x09CD..0x09CD,
    0x09E2..0x09E3,
    0x200B..0x200F,
    0xFEFF..0xFEFF
  ]

  defp char_width(char) do
    cond do
      Enum.any?(@zero, &(char in &1)) -> 0
      Enum.any?(@wide, &(char in &1)) -> 2
      true -> 1
    end
  end
end
