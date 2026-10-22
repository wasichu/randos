# Integration tests need a running randos server (just tui-smoke starts one).
#
# :native tests need the media helper built (cargo build -p randos_media;
# just precommit does). They're skipped when it isn't, unless
# RANDOS_REQUIRE_NATIVE=1 (set it in CI), which turns a missing helper into
# failures instead of a silent skip.
require_native? = System.get_env("RANDOS_REQUIRE_NATIVE") == "1"
run_native? = require_native? or File.regular?(Tui.Media.default_helper_path())

# Many tests wait on a real helper process; the 100 ms default flakes when
# precommit or CI is busy compiling. This only lengthens failing waits.
ExUnit.start(
  exclude: [:integration, :relay_only, :recovery] ++ if(run_native?, do: [], else: [:native]),
  assert_receive_timeout: 2_000
)
