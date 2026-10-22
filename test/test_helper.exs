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

# The rule for waits in tests (AGENTS.md, Testing): a wait for something to
# happen allows at least 5 s, since only a failing wait runs that long and CI
# runners are slower than a laptop (2 s flaked more than once). Assertions
# about timing itself (a short test timer firing on time) keep their own
# bounds. refute_receive keeps its short default. The TUI's tests do the same.
ExUnit.start(exclude: exclude, assert_receive_timeout: 5_000)
