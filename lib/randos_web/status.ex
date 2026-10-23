defmodule RandosWeb.Status do
  @moduledoc """
  Everything the public status page shows, as one JSON-safe map: the
  relay's health (`RandosWeb.RelayHealth`) and today's aggregate counts
  (`Randos.Stats`), already filtered for publishing (small counts
  suppressed, coarse times). The web page (`RandosWeb.StatusLive`) renders
  only from this, and other clients (the TUI) can be sent the same map.

  `snapshot/0` reads the live processes: the relay as this node sees it,
  and the counts summed over every node in the cluster
  (`Randos.Stats.snapshot/1`); `build/2` is the pure part, from a relay
  status and a stats snapshot, so it can be tested on its own.

  The shape (string keys; times ISO 8601 in UTC, to the minute or second):

      %{
        "relay" => %{
          "state" => "ok" | "degraded" | "down" | "checking" | "not_configured",
          "scope" => "this_node",   # each node checks the relay for itself
          "checked_at" => "2026-10-21T14:05:00Z" | nil,
          "transports" => [%{"transport" => "udp" | "tls", "ok" => true, "reason" => nil}]
        },
        "usage" => %{
          "date" => "2026-10-21",
          "since" => "2026-10-21T09:12:00Z",
          "calls_started" => 12,
          "calls_connected" => 9,
          "calls_continued" => 2,        # calls that ran past their first continued_after_minutes
          "continued_after_minutes" => 10,
          "median_minutes" => 8 | nil,   # whole minutes; longest_minutes means that or more
          "longest_minutes" => 30,
          "endings" => %{"finished" => 8, "not_connected" => 2, "connection_lost" => 1, "canceled" => 1},
          "language_pairs" => [%{"languages" => ["en", "es"], "calls" => 5}],
          "other_pairs_calls" => 3,
          "nodes" => %{"answered" => 1, "total" => 1},  # servers counted, of those asked
          "kept_across_restarts" => true   # false: memory only (no RANDOS_STATS_DIR)
        }
      }
  """

  alias Randos.Calls.Lifecycle
  alias Randos.Stats
  alias RandosWeb.RelayHealth

  @endings ~w(finished not_connected connection_lost canceled)a

  @doc "The status from the running processes."
  @spec snapshot() :: map()
  def snapshot,
    do:
      build(
        RelayHealth.status(),
        Stats.snapshot(),
        Application.get_env(:randos, :stats_dir) != nil
      )

  @doc "The status from a relay status and a stats snapshot (pure)."
  @spec build(RelayHealth.status(), map()) :: map()
  def build(relay, stats, kept? \\ false),
    do: %{"relay" => relay(relay), "usage" => usage(stats, kept?)}

  # The relay as this node sees it ("scope": each node checks for itself).
  defp relay(%{configured: false}),
    do: %{
      "state" => "not_configured",
      "scope" => "this_node",
      "checked_at" => nil,
      "transports" => []
    }

  defp relay(status) do
    transports =
      for transport <- [:udp, :tls], result = status.results[transport], result != nil do
        %{
          "transport" => Atom.to_string(transport),
          "ok" => result.ok,
          "reason" => result.reason && Atom.to_string(result.reason)
        }
      end

    %{
      "state" => relay_state(status, transports),
      "scope" => "this_node",
      "checked_at" => iso(status.checked_at),
      "transports" => transports
    }
  end

  defp relay_state(%{checking: true, checked_at: nil}, _transports), do: "checking"
  defp relay_state(_status, []), do: "checking"

  defp relay_state(_status, transports) do
    case Enum.count(transports, & &1["ok"]) do
      0 -> "down"
      n when n == length(transports) -> "ok"
      _some -> "degraded"
    end
  end

  defp usage(stats, kept?) do
    %{
      "date" => Date.to_iso8601(stats.date),
      "since" => stats.since |> minute() |> iso(),
      "calls_started" => stats.started,
      "calls_connected" => stats.connected,
      "calls_continued" => stats.extended,
      "continued_after_minutes" => div(Lifecycle.call_duration_seconds(), 60),
      "median_minutes" => stats.median_minutes,
      "longest_minutes" => Stats.last_bucket(),
      "endings" => Map.new(@endings, &{Atom.to_string(&1), Map.get(stats.endings, &1, 0)}),
      "language_pairs" =>
        Enum.map(stats.pairs, fn {{a, b}, calls} -> %{"languages" => [a, b], "calls" => calls} end),
      "other_pairs_calls" => stats.other_pairs,
      "nodes" => %{"answered" => stats.nodes.answered, "total" => stats.nodes.total},
      "kept_across_restarts" => kept?
    }
  end

  # Coarse: "counting since" to the minute.
  defp minute(%DateTime{} = at), do: %{at | second: 0, microsecond: {0, 0}}

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
