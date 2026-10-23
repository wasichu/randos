defmodule Randos.Eventually do
  @moduledoc """
  Waits in tests until something holds: `fun` is retried every 10 ms until
  it returns something truthy (returned) or `timeout_ms` passes (its last
  falsy result). 5 s by default: only a failing wait ever runs that long,
  and CI is slower than a laptop (AGENTS.md, "Waits in tests").
  """

  @interval_ms 10

  @spec eventually((-> term()), pos_integer()) :: term()
  def eventually(fun, timeout_ms \\ 5_000),
    do: poll(fun, System.monotonic_time(:millisecond) + timeout_ms)

  defp poll(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@interval_ms)
          poll(fun, deadline)
        else
          falsy
        end

      value ->
        value
    end
  end
end
