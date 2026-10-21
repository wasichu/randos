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

ExUnit.start(exclude: exclude)
