defmodule Randos.StatsClusterTest do
  # A second node, started with OTP's :peer: the published counts are the
  # sums over both nodes, and the privacy filter applies to the sums.
  use ExUnit.Case, async: false

  alias Randos.Stats

  @moduletag :distributed

  setup do
    name = :"stats_cluster_#{System.unique_integer([:positive])}"

    # The peer is linked to this test process (:peer.start_link), so it stops
    # when the test process exits, however the test ends (on_exit runs after
    # that, so there's nothing left to stop).
    {:ok, _peer, peer_node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    start_supervised!({Stats, name: name, attach: false, pubsub: nil})

    {:ok, _pid} =
      :erpc.call(peer_node, :gen_server, :start, [
        {:local, name},
        Stats,
        [name: name, attach: false, pubsub: nil],
        []
      ])

    %{name: name, peer_node: peer_node}
  end

  # Starts and ends one connected call on `node`'s stats.
  defp call_on(node, name, languages) do
    :ok =
      :erpc.call(node, Stats, :handle_telemetry, [
        [:randos, :call, :start],
        %{},
        %{call_id: "x", languages: languages},
        name
      ])

    :ok =
      :erpc.call(node, Stats, :handle_telemetry, [
        [:randos, :call, :stop],
        %{duration: 0, connected: System.convert_time_unit(300, :second, :native)},
        %{call_id: "x", reason: :completed, extension_count: 0},
        name
      ])
  end

  test "counts from every node add up; a pair with 2 calls on each node shows (4 in all)", %{
    name: name,
    peer_node: peer_node
  } do
    assert peer_node in Node.list()

    for node <- [node(), peer_node], _ <- 1..2, do: call_on(node, name, ["en", "es"])
    call_on(peer_node, name, ["de", "fr"])

    # Each node alone would hide the pair (2 calls, under the threshold of 3).
    assert %{pairs: []} = Stats.publish(Stats.raw(name))

    assert %{
             started: 5,
             connected: 5,
             endings: %{finished: 5},
             median_minutes: 5,
             pairs: [{{"en", "es"}, 4}],
             other_pairs: 1,
             nodes: %{answered: 2, total: 2}
           } = Stats.snapshot(name)
  end

  test "a node that doesn't answer is left out, and the snapshot says so", %{
    name: name,
    peer_node: peer_node
  } do
    call_on(node(), name, ["en", "es"])
    # The peer has no stats process under this name any more.
    :ok = :erpc.call(peer_node, :gen_server, :stop, [name])

    assert %{started: 1, nodes: %{answered: 1, total: 2}} = Stats.snapshot(name)
  end
end
