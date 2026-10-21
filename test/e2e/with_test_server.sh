#!/usr/bin/env bash
# Runs a command against a throwaway dev server on :4010, then stops it.
# Used by `just smoke` and `just tui-smoke`, so both start the server the same
# way: 8 s call segments (to reach the extension vote quickly; set
# RANDOS_CALL_SEGMENT_MS to override, as `just screenshots` does), a 4 s
# connect timeout (so the never-connects scenarios finish fast), and no ICE
# servers (nothing reaches the internet; host candidates connect locally).
#
#   test/e2e/with_test_server.sh <server log> <command> [args...]
#
# The server can't outlive this script: besides the EXIT trap, a watchdog in
# the server halts it within a second or two once this script is gone (even
# after kill -9, which skips the trap). And a server already on :4010 is an
# error, never reused, so tests can't run against stale code.
set -euo pipefail

log="$1"
shift

if curl -sf -o /dev/null --max-time 2 http://localhost:4010/; then
  echo "error: something already serves :4010 (a leftover test server?)." >&2
  echo "  see it with: lsof -nP -iTCP:4010 -sTCP:LISTEN" >&2
  exit 1
fi

# Halts the VM once the process that started it ($RANDOS_TEST_PARENT_PID) is gone.
watchdog='
parent = System.fetch_env!("RANDOS_TEST_PARENT_PID")
alive? = fn -> match?({_, 0}, System.cmd("kill", ["-0", parent], stderr_to_stdout: true)) end
spawn(fn ->
  Stream.repeatedly(fn -> Process.sleep(1_000); alive?.() end) |> Enum.find(&(not &1))
  IO.puts(:stderr, "test server: the script that started it is gone; halting")
  System.halt(1)
end)
'

mkdir -p "$(dirname "$log")"
export RANDOS_CONNECT_TIMEOUT_MS=4000 RANDOS_ICE_SERVERS='[]'
# A developer's TURN settings (`just dev-turn`) must not leak into tests.
unset TURN_SHARED_SECRET TURN_HOST TURN_SERVER_URL TURNS_SERVER_URL TURN_STUN_URL RANDOS_ALLOW_DIRECT_CALLS
# RANDOS_TEST_UNREACHABLE_RELAY=1: a TURN server that never answers, so calls
# are relay-only and can't connect; a client that connected anyway went
# direct, against the policy (the relay-only obligation tests).
if [ "${RANDOS_TEST_UNREACHABLE_RELAY:-}" = 1 ]; then
  export TURN_SERVER_URL=turn:127.0.0.1:9 TURN_SHARED_SECRET=test-only-secret
fi
RANDOS_TEST_PARENT_PID=$$ PORT=4010 HTTPS_PORT=4011 RANDOS_CALL_SEGMENT_MS="${RANDOS_CALL_SEGMENT_MS:-8000}" \
  elixir -e "$watchdog" -S mix phx.server > "$log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do curl -sf -o /dev/null http://localhost:4010/ && break; sleep 1; done

"$@"
