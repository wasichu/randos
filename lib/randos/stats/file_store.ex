defmodule Randos.Stats.FileStore do
  @moduledoc """
  Keeps `Randos.Stats`' daily counters across restarts: one small JSON file
  per UTC day, `<dir>/<date>.json`, in the directory `RANDOS_STATS_DIR`
  names (production: a Fly volume at `/data/stats`).

  The file holds only the aggregate counters (`Randos.Stats.raw/1`): counts,
  a histogram of call lengths, and calls per language pair. No addresses,
  ids, or anything about a person, so it's plain JSON on purpose: anyone can
  read exactly what's kept. Writes are atomic (a temporary file, then a
  rename), and a failure is logged, never raised: counting must never take
  the app down.
  """

  require Logger

  @doc "The day's saved counters, or `nil` (none saved, or unreadable)."
  @spec load(Date.t()) :: map() | nil
  def load(date) do
    with dir when is_binary(dir) <- dir(),
         {:ok, json} <- File.read(path(dir, date)),
         {:ok, saved} <- JSON.decode(json),
         {:ok, raw} <- decode(saved, date) do
      raw
    else
      nil ->
        nil

      {:error, :enoent} ->
        nil

      other ->
        Logger.warning("stats: ignoring unreadable saved counters", reason: inspect(other))
        nil
    end
  end

  @doc "Saves the day's counters (nothing without a directory)."
  @spec save(Date.t(), map()) :: :ok
  def save(date, raw) do
    case dir() do
      nil -> :ok
      dir -> write(dir, date, raw)
    end
  end

  defp write(dir, date, raw) do
    path = path(dir, date)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, JSON.encode_to_iodata!(encode(raw))),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("stats: couldn't save counters", reason: inspect(reason))
        :ok
    end
  end

  defp dir, do: Application.get_env(:randos, :stats_dir)

  defp path(dir, date), do: Path.join(dir, Date.to_iso8601(date) <> ".json")

  ## JSON shape: pair keys become "en-es", minute keys strings.

  @doc false
  def encode(raw) do
    %{
      "date" => Date.to_iso8601(raw.date),
      "since" => DateTime.to_iso8601(raw.since),
      "started" => raw.started,
      "connected" => raw.connected,
      "extended" => raw.extended,
      "endings" => Map.new(raw.endings, fn {class, n} -> {Atom.to_string(class), n} end),
      "lengths" => Map.new(raw.lengths, fn {minute, n} -> {Integer.to_string(minute), n} end),
      "pairs" => Map.new(raw.pairs, fn {{a, b}, n} -> {a <> "-" <> b, n} end)
    }
  end

  @endings ~w(finished not_connected connection_lost canceled)

  @doc false
  def decode(%{"date" => date, "since" => since} = saved, expected) do
    with {:ok, ^expected} <- Date.from_iso8601(date),
         {:ok, since, _offset} <- DateTime.from_iso8601(since),
         {:ok, endings} <- decode_map(saved["endings"], &ending/1),
         {:ok, lengths} <- decode_map(saved["lengths"], &minute/1),
         {:ok, pairs} <- decode_map(saved["pairs"], &pair/1) do
      {:ok,
       %{
         date: expected,
         since: since,
         started: count(saved["started"]),
         connected: count(saved["connected"]),
         extended: count(saved["extended"]),
         endings: endings,
         lengths: lengths,
         pairs: pairs
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  def decode(_saved, _expected), do: {:error, :invalid}

  defp decode_map(map, key_fun) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, n}, {:ok, acc} ->
      case key_fun.(key) do
        {:ok, key} when is_integer(n) and n >= 0 -> {:cont, {:ok, Map.put(acc, key, n)}}
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp decode_map(_not_a_map, _key_fun), do: :error

  # Never String.to_atom on file contents: only the known classes.
  defp ending(class) when class in @endings, do: {:ok, String.to_existing_atom(class)}
  defp ending(_class), do: :error

  defp minute(key) do
    case Integer.parse(key) do
      {minute, ""} when minute >= 0 -> {:ok, minute}
      _invalid -> :error
    end
  end

  defp pair(key) do
    case String.split(key, "-") do
      [a, b] when a != "" and b != "" -> {:ok, {a, b}}
      _invalid -> :error
    end
  end

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_invalid), do: 0
end
