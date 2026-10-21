defmodule Randos.TestDistribution do
  @moduledoc """
  Makes the test VM a distributed node, for the tests tagged `:distributed`
  (they start peer nodes with OTP's `:peer`). Needs epmd: an epmd that's
  already running is used as is; otherwise one is started for this test run
  under a shell that kills it when this VM's end of the pipe closes, so it
  can't outlive the run however the run ends (`kill -9` included), like the
  other helpers tests start.

  `start/0` returns `:ok`, or `{:error, why}` (the tests are then skipped).
  """

  @spec start() :: :ok | {:error, String.t()}
  def start do
    with :ok <- ensure_epmd(), do: start_node()
  end

  defp ensure_epmd do
    cond do
      epmd_up?() -> :ok
      epmd = System.find_executable("epmd") -> start_epmd(epmd)
      true -> {:error, "no epmd executable on PATH"}
    end
  end

  # epmd in the foreground, in a shell that waits for its stdin (our Port)
  # to close and then kills it.
  defp start_epmd(epmd) do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      args: ["-c", ~s("$0" & pid=$!; cat >/dev/null; kill "$pid"), epmd]
    ])

    if wait_for_epmd(50), do: :ok, else: {:error, "epmd didn't start"}
  end

  defp wait_for_epmd(0), do: false

  defp wait_for_epmd(tries) do
    epmd_up?() or (Process.sleep(100) && wait_for_epmd(tries - 1))
  end

  defp epmd_up?, do: match?({:ok, _names}, :erl_epmd.names())

  defp start_node do
    if Node.alive?() do
      :ok
    else
      case Node.start(:"randos_test_#{System.unique_integer([:positive])}", :shortnames) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, "couldn't start distribution: #{inspect(reason)}"}
      end
    end
  end
end
