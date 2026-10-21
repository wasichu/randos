# :distributed tests start peer nodes (OTP's :peer), so this VM must be a
# distributed node first (Randos.TestDistribution). Where that can't be
# done, they're skipped, saying why.
exclude =
  case Randos.TestDistribution.start() do
    :ok ->
      []

    {:error, why} ->
      IO.puts("Skipping :distributed tests: #{why}.")
      [:distributed]
  end

# assert_receive waits up to 2 s (ExUnit's default is 100 ms): processes
# here answer within milliseconds, but a busy CI runner can take longer,
# which flaked tests more than once. Only failing waits get longer;
# refute_receive keeps its own short default. (The TUI's tests do the same.)
ExUnit.start(exclude: exclude, assert_receive_timeout: 2_000)
