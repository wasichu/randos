defmodule RandosWeb.StatusTest do
  use ExUnit.Case, async: true

  alias RandosWeb.Status

  @stats %{
    date: ~D[2026-10-21],
    since: ~U[2026-10-21 09:12:33Z],
    started: 6,
    connected: 5,
    extended: 1,
    endings: %{finished: 4, not_connected: 1},
    median_minutes: 9,
    pairs: [{{"en", "es"}, 3}],
    other_pairs: 3,
    nodes: %{answered: 2, total: 3}
  }

  test "a JSON-safe snapshot: string keys, ISO times, coarse 'since'" do
    relay = %{
      configured: true,
      checking: false,
      checked_at: ~U[2026-10-21 14:05:07Z],
      results: %{udp: %{ok: true, reason: nil}, tls: %{ok: false, reason: "no answer"}}
    }

    snapshot = Status.build(relay, @stats)

    assert snapshot == %{
             "relay" => %{
               "state" => "degraded",
               "scope" => "this_node",
               "checked_at" => "2026-10-21T14:05:07Z",
               "transports" => [
                 %{"transport" => "udp", "ok" => true, "reason" => nil},
                 %{"transport" => "tls", "ok" => false, "reason" => "no answer"}
               ]
             },
             "usage" => %{
               "date" => "2026-10-21",
               "since" => "2026-10-21T09:12:00Z",
               "calls_started" => 6,
               "calls_connected" => 5,
               "calls_continued" => 1,
               "median_minutes" => 9,
               "endings" => %{
                 "finished" => 4,
                 "not_connected" => 1,
                 "connection_lost" => 0,
                 "canceled" => 0
               },
               "language_pairs" => [%{"languages" => ["en", "es"], "calls" => 3}],
               "other_pairs_calls" => 3,
               "nodes" => %{"answered" => 2, "total" => 3}
             }
           }

    assert {:ok, _json} = Jason.encode(snapshot)
  end

  test "relay states" do
    state = fn relay -> Status.build(relay, @stats)["relay"]["state"] end
    ok = %{ok: true, reason: nil}
    down = %{ok: false, reason: "no answer"}
    base = %{configured: true, checking: false, checked_at: ~U[2026-10-21 14:05:07Z]}

    assert state.(%{base | configured: false} |> Map.put(:results, %{})) == "not_configured"
    assert state.(Map.put(%{base | checked_at: nil, checking: true}, :results, %{})) == "checking"
    assert state.(Map.put(base, :results, %{udp: ok, tls: ok})) == "ok"
    assert state.(Map.put(base, :results, %{udp: down, tls: down})) == "down"
  end
end
