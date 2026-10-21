defmodule RandosDev.TranslationReview do
  @moduledoc """
  The translation shootout's review data (Phase 6): `results/review.json`
  from `tools/translate` (`python -m randos_translate.cli review`), which
  combines every run into, per locale, each string's translations side by
  side with their scores, failed checks, how much the models disagree, and
  whether the evaluators disagree. `RandosDev.TranslationReviewLive` shows
  it; the logic lives in `tools/translate/randos_translate/review.py`.
  """

  @default_path "tools/translate/results/review.json"

  @doc "The review file's default path (relative to the project root)."
  def default_path, do: Path.expand(@default_path, File.cwd!())

  @doc "Reads and decodes a review file."
  @spec load(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"locales" => locales} = review} when map_size(locales) > 0 <- JSON.decode(body) do
      {:ok, review}
    else
      {:error, :enoent} -> {:error, "no review yet at #{path}"}
      {:error, reason} when is_atom(reason) -> {:error, "can't read #{path}: #{reason}"}
      _other -> {:error, "#{path} isn't a review file"}
    end
  end

  @filters ~w(all disagree conflict failed)

  @doc "The filters, in display order."
  def filters, do: @filters

  @doc """
  A locale's strings for a filter: `"disagree"` (the models translated it
  differently, disagreement of at least 0.3), `"conflict"` (the evaluators
  disagree on the best model), `"failed"` (some model failed a check), or
  `"all"`. Already sorted most-disagreed first by the review.
  """
  def strings(%{"strings" => strings}, filter), do: Enum.filter(strings, &matches?(&1, filter))

  defp matches?(_row, "all"), do: true
  defp matches?(row, "disagree"), do: row["disagreement"] >= 0.3
  defp matches?(row, "conflict"), do: row["conflict"] != nil

  defp matches?(row, "failed"),
    do: Enum.any?(row["translations"], fn {_model, t} -> t["failed"] != [] end)

  @doc "A stable DOM id fragment for a string's key."
  def key_id(key), do: key |> :erlang.phash2() |> Integer.to_string(36)
end
