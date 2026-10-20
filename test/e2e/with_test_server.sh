#!/usr/bin/env bash
# Runs a command against a throwaway dev server on :4010, then stops it.
# Used by `just smoke` and `just tui-smoke`, so both start the server the same
# way: 8 s call segments (to reach the extension vote quickly) and a 4 s
# connect timeout (so the never-connects scenarios finish fast).
#
#   test/e2e/with_test_server.sh <server log> <command> [args...]
set -euo pipefail

log="$1"
shift

mkdir -p "$(dirname "$log")"
export RANDOS_CONNECT_TIMEOUT_MS=4000
PORT=4010 HTTPS_PORT=4011 RANDOS_CALL_SEGMENT_MS=8000 mix phx.server > "$log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do curl -sf -o /dev/null http://localhost:4010/ && break; sleep 1; done

"$@"
