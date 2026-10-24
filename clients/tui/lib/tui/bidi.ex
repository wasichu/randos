defmodule Tui.Bidi do
  @moduledoc """
  Right-to-left text in display order, for terminals that don't reorder it
  themselves (Ghostty, Alacritty, Windows Terminal, VS Code's: see
  `Tui.Terminal`). The Unicode bidi algorithm for one left-to-right line,
  as much of it as our text needs: Arabic and Hebrew runs read right to
  left, numbers inside them keep their own order, the spaces and
  punctuation between two right-to-left words go with them, brackets in a
  right-to-left run are mirrored. A terminal that does reorder gets the
  text as it is (`Tui.Terminal.bidi/1`), or it would turn it back.

  Also `wrap/2`: the same text broken into lines of a width, by words, so
  each screen line is reordered on its own (a line can't be reordered
  before it's known where it breaks).
  """

  alias Tui.Width

  @mirrors %{
    "(" => ")",
    ")" => "(",
    "[" => "]",
    "]" => "[",
    "{" => "}",
    "}" => "{",
    "<" => ">",
    ">" => "<",
    "«" => "»",
    "»" => "«"
  }

  @doc "`line` (no line breaks) in left-to-right display order."
  @spec visual(String.t()) :: String.t()
  def visual(line) do
    graphemes = String.graphemes(line)
    types = graphemes |> Enum.map(&type/1) |> brackets(graphemes) |> resolve()

    if :r in types do
      graphemes
      |> Enum.zip(types)
      |> Enum.map(fn {g, t} -> {if(t == :r, do: Map.get(@mirrors, g, g), else: g), level(t)} end)
      |> reorder(2)
      |> reorder(1)
      |> Enum.map_join(&elem(&1, 0))
    else
      line
    end
  end

  @doc """
  `text` broken into lines of at most `width` cells, by words; a word too
  long for a line (a link) is broken across lines, never cut.
  """
  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  def wrap(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn
      "" ->
        [""]

      paragraph ->
        paragraph |> String.split(" ") |> Enum.flat_map(&pieces(&1, width)) |> pack(width)
    end)
  end

  # A word wider than a line, in pieces that each fit.
  defp pieces(word, width) do
    if Width.of(word) <= width do
      [word]
    else
      word
      |> String.graphemes()
      |> Enum.chunk_while("", &fill_piece(&1, &2, width), fn acc -> {:cont, acc, ""} end)
    end
  end

  defp fill_piece(grapheme, acc, width) do
    if Width.of(acc <> grapheme) <= width,
      do: {:cont, acc <> grapheme},
      else: {:cont, acc, grapheme}
  end

  defp pack(words, width) do
    words
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | done] ->
        joined = line <> " " <> word
        if Width.of(joined) <= width, do: [joined | done], else: [word, line | done]
    end)
    |> Enum.reverse()
    |> Enum.map(&Width.fit(&1, width))
  end

  # Strong right-to-left letters; Arabic-Indic digits; European digits;
  # strong left-to-right (letters of other scripts); neutral (the rest).
  @arabic_digits [0x0660..0x0669, 0x06F0..0x06F9]
  # Hebrew and Arabic (with their supplements and presentation forms).
  @right_to_left [0x0590..0x08FF, 0xFB1D..0xFDFF, 0xFE70..0xFEFF]

  defp type(grapheme) do
    <<cp::utf8, _::binary>> = grapheme

    cond do
      in_any?(cp, @arabic_digits) -> :an
      in_any?(cp, @right_to_left) -> :r
      cp in ?0..?9 -> :en
      grapheme in [".", ",", ":", "/"] -> :cs
      String.match?(grapheme, ~r/\p{L}/u) -> :l
      true -> :n
    end
  end

  defp in_any?(cp, ranges), do: Enum.any?(ranges, &(cp in &1))

  # Numbers after right-to-left text (the nearest strong before them) are
  # Arabic numbers (rule W2); neutrals take the direction of the strong
  # text on both sides, else the line's, left to right (N1, N2).
  defp resolve(types) do
    types = types |> numbers(:l, []) |> separators()
    strong = Enum.map(types, &strong/1)
    before = Enum.scan(strong, :l, fn s, last -> s || last end)

    after_ =
      strong |> Enum.reverse() |> Enum.scan(:l, fn s, last -> s || last end) |> Enum.reverse()

    [types, before, after_]
    |> Enum.zip()
    |> Enum.map(fn
      {:n, :r, :r} -> :r
      {:n, _before, _after} -> :l
      {type, _before, _after} -> type
    end)
  end

  defp numbers([], _last, acc), do: Enum.reverse(acc)
  defp numbers([:en | rest], :r, acc), do: numbers(rest, :r, [:an | acc])

  defp numbers([type | rest], _last, acc) when type in [:l, :r],
    do: numbers(rest, type, [type | acc])

  defp numbers([type | rest], last, acc), do: numbers(rest, last, [type | acc])

  # Rule N0, as far as we need it: a bracket pair with right-to-left text
  # inside and none left to right, after right-to-left text, is right to
  # left ("لغة (عربي)"), so the pair moves with its words.
  @opening %{"(" => ")", "[" => "]", "{" => "}"}

  defp brackets(types, graphemes) do
    graphemes
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {g, i}, {stack, pairs} ->
      cond do
        Map.has_key?(@opening, g) -> {[{@opening[g], i} | stack], pairs}
        match?([{^g, _} | _], stack) -> {tl(stack), [{elem(hd(stack), 1), i} | pairs]}
        true -> {stack, pairs}
      end
    end)
    |> elem(1)
    |> Enum.reduce(List.to_tuple(types), fn {open, close}, acc ->
      inside = for i <- (open + 1)..(close - 1)//1, do: elem(acc, i)

      before =
        acc
        |> Tuple.to_list()
        |> Enum.take(open)
        |> Enum.reverse()
        |> Enum.find(&(&1 in [:l, :r]))

      if :r in inside and :l not in inside and before == :r,
        do: acc |> put_elem(open, :r) |> put_elem(close, :r),
        else: acc
    end)
    |> Tuple.to_list()
  end

  # A single separator between two numbers of a kind is part of them
  # ("4:59", "1,000"), rule W4; any other is neutral.
  defp separators([a, :cs, b | rest]) when a == b and a in [:en, :an],
    do: [a | separators([a, b | rest])]

  defp separators([:cs | rest]), do: [:n | separators(rest)]
  defp separators([type | rest]), do: [type | separators(rest)]
  defp separators([]), do: []

  # Numbers count as right-to-left for the neutrals around them.
  defp strong(:l), do: :l
  defp strong(:en), do: :l
  defp strong(type) when type in [:r, :an], do: :r
  defp strong(:n), do: nil

  defp level(:r), do: 1
  defp level(:an), do: 2
  defp level(_left_to_right), do: 0

  # Rule L2: from the highest level down, reverse every run at that level
  # or above.
  defp reorder(cells, min) do
    cells
    |> Enum.chunk_by(fn {_g, level} -> level >= min end)
    |> Enum.flat_map(fn [{_g, level} | _] = run ->
      if level >= min, do: Enum.reverse(run), else: run
    end)
  end
end
