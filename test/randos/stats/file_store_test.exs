defmodule Randos.Stats.FileStoreTest do
  # The store reads the app's :stats_dir, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Randos.Stats
  alias Randos.Stats.FileStore

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:randos, :stats_dir, dir)
    on_exit(fn -> Application.delete_env(:randos, :stats_dir) end)
    %{dir: dir}
  end

  @date ~D[2026-10-21]

  defp raw do
    %{
      Stats.empty(@date, ~U[2026-10-21 09:12:00Z])
      | started: 12,
        connected: 9,
        extended: 2,
        endings: %{finished: 8, not_connected: 2, connection_lost: 1},
        lengths: %{0 => 1, 4 => 2, 10 => 5, 30 => 1},
        pairs: %{{"en", "es"} => 5, {"de", "fr"} => 1}
    }
  end

  test "a day's counters round-trip through a readable JSON file", %{dir: dir} do
    assert FileStore.save(@date, raw()) == :ok
    assert FileStore.load(@date) == raw()

    # Plain JSON, nothing but the aggregates.
    saved = dir |> Path.join("2026-10-21.json") |> File.read!() |> JSON.decode!()
    assert saved["pairs"] == %{"en-es" => 5, "de-fr" => 1}

    assert Map.keys(saved) |> Enum.sort() ==
             ~w(connected date endings extended lengths pairs since started)

    # Another day has nothing yet.
    assert FileStore.load(~D[2026-10-22]) == nil
  end

  test "an unreadable or tampered file is ignored, not trusted", %{dir: dir} do
    path = Path.join(dir, "2026-10-21.json")

    for bad <- [
          "not json",
          ~s({"date": "2026-10-20", "since": "2026-10-20T00:00:00Z"}),
          ~s({"date": "2026-10-21", "since": "2026-10-21T00:00:00Z", "endings": {"pwned": 1}}),
          ~s({"date": "2026-10-21", "since": "2026-10-21T00:00:00Z", "pairs": {"en-es": -4}})
        ] do
      File.write!(path, bad)
      assert capture_log(fn -> assert FileStore.load(@date) == nil end) =~ "unreadable"
    end
  end

  test "without a directory nothing is kept" do
    Application.delete_env(:randos, :stats_dir)
    assert FileStore.save(@date, raw()) == :ok
    assert FileStore.load(@date) == nil
  end

  test "a restarted Stats picks up the day's counts where it left off" do
    now = ~U[2026-10-21 12:00:00Z]
    name = :"stats_store_#{System.unique_integer([:positive])}"
    opts = [name: name, attach: false, pubsub: nil, store: FileStore, now: fn -> now end]

    start_supervised!({Stats, opts}, id: :first)

    for _ <- 1..3 do
      Stats.handle_telemetry(
        [:randos, :call, :start],
        %{},
        %{call_id: "x", languages: ["en", "es"]},
        name
      )
    end

    assert %{started: 3} = Stats.raw(name)
    stop_supervised!(:first)

    start_supervised!({Stats, opts}, id: :second)
    assert %{started: 3, pairs: %{{"en", "es"} => 3}} = Stats.raw(name)
  end
end
