defmodule Randos.StatsTest do
  use ExUnit.Case, async: true

  alias Randos.Stats

  # An isolated instance, fed directly (not through global telemetry), with
  # a clock the test moves.
  defp start_stats(now) do
    clock = Agent.start_link(fn -> now end) |> elem(1)
    name = :"stats_#{System.unique_integer([:positive])}"
    pubsub = :"stats_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    start_supervised!(
      {Stats, name: name, attach: false, pubsub: pubsub, now: fn -> Agent.get(clock, & &1) end}
    )

    %{stats: name, clock: clock, pubsub: pubsub}
  end

  defp call(stats, languages, reason, opts \\ []) do
    Stats.handle_telemetry(
      [:randos, :call, :start],
      %{},
      %{call_id: "x", languages: languages},
      stats
    )

    connected =
      case Keyword.get(opts, :connected_s) do
        nil -> nil
        seconds -> System.convert_time_unit(seconds, :second, :native)
      end

    Stats.handle_telemetry(
      [:randos, :call, :stop],
      %{duration: 0, connected: connected},
      %{call_id: "x", reason: reason, extension_count: Keyword.get(opts, :extensions, 0)},
      stats
    )
  end

  test "counts calls, endings, continuations and lengths; publishes only pairs with 3+ calls" do
    %{stats: stats} = start_stats(~U[2026-10-21 09:12:33Z])

    for _ <- 1..3, do: call(stats, ["en", "es"], :completed, connected_s: 600)
    call(stats, ["es", "es"], :hangup, connected_s: 300, extensions: 1)
    call(stats, ["de", "fr"], :connection_failed)
    call(stats, ["fr", "ko"], :disconnected, connected_s: 120)

    snapshot = Stats.snapshot(stats)

    assert %{
             started: 6,
             connected: 5,
             extended: 1,
             endings: %{finished: 4, not_connected: 1, connection_lost: 1},
             median_minutes: 10,
             pairs: [{{"en", "es"}, 3}],
             other_pairs: 3
           } = snapshot

    assert snapshot.date == ~D[2026-10-21]
    assert snapshot.since == ~U[2026-10-21 09:12:33Z]
    # Nothing identifying is kept: the published map has no ids.
    refute inspect(snapshot) =~ ~s("x")
  end

  test "the median waits for 3 connected calls" do
    %{stats: stats} = start_stats(~U[2026-10-21 09:00:00Z])
    call(stats, ["en", "es"], :completed, connected_s: 100)
    call(stats, ["en", "es"], :completed, connected_s: 200)
    assert %{median_minutes: nil} = Stats.snapshot(stats)
  end

  test "a new UTC day starts from zero, counting from midnight" do
    %{stats: stats, clock: clock} = start_stats(~U[2026-10-21 23:59:00Z])
    call(stats, ["en", "es"], :completed, connected_s: 100)
    assert %{started: 1} = Stats.snapshot(stats)

    Agent.update(clock, fn _ -> ~U[2026-10-22 00:01:00Z] end)

    assert %{started: 0, date: ~D[2026-10-22], since: ~U[2026-10-22 00:00:00Z]} =
             Stats.snapshot(stats)
  end

  test "lengths are a histogram of whole minutes; the longest share the last bucket" do
    %{stats: stats} = start_stats(~U[2026-10-21 09:00:00Z])
    call(stats, ["en", "es"], :completed, connected_s: 59)
    call(stats, ["en", "es"], :completed, connected_s: 61)
    call(stats, ["en", "es"], :max_duration_reached, connected_s: 1_900)

    assert %{lengths: %{0 => 1, 1 => 1, 30 => 1}} = Stats.raw(stats)
    assert %{median_minutes: 1} = Stats.snapshot(stats)
  end

  describe "merging nodes' counters (a future cluster)" do
    defp raw(since, fields), do: Map.merge(Stats.empty(DateTime.to_date(since), since), fields)

    test "counters add up exactly; since is the earliest" do
      a =
        raw(~U[2026-10-21 09:00:00Z], %{
          started: 2,
          endings: %{finished: 2},
          lengths: %{3 => 2},
          pairs: %{{"en", "es"} => 2}
        })

      b =
        raw(~U[2026-10-21 08:00:00Z], %{
          started: 1,
          endings: %{not_connected: 1},
          lengths: %{3 => 1, 7 => 1},
          pairs: %{{"en", "es"} => 1, {"de", "fr"} => 1}
        })

      assert %{
               since: ~U[2026-10-21 08:00:00Z],
               started: 3,
               endings: %{finished: 2, not_connected: 1},
               lengths: %{3 => 3, 7 => 1},
               pairs: %{{"en", "es"} => 3, {"de", "fr"} => 1}
             } = Stats.merge(a, b)
    end

    test "the privacy filter runs after merging: a pair under 3 on each node can show in total" do
      a = raw(~U[2026-10-21 09:00:00Z], %{pairs: %{{"en", "es"} => 2}})
      b = raw(~U[2026-10-21 09:00:00Z], %{pairs: %{{"en", "es"} => 1}})

      assert %{pairs: [], other_pairs: 2} = Stats.publish(a)
      assert %{pairs: [{{"en", "es"}, 3}], other_pairs: 0} = Stats.publish(Stats.merge(a, b))
    end
  end

  test "announces each change" do
    %{stats: stats, pubsub: pubsub} = start_stats(~U[2026-10-21 09:00:00Z])
    Phoenix.PubSub.subscribe(pubsub, Stats.topic())
    call(stats, ["en", "es"], :completed, connected_s: 100)
    assert_receive {:stats_updated, %{started: 1}}
  end
end
