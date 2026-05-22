#!/usr/bin/env bash
# Story 137 (backlog 157) — MCP server self-detects when its source has
# been modified on disk since startup, and returns a clear JSON-RPC error
# pointing the caller at /reload-plugins. Closes the stale-server class
# that left Story 103's sprint-mode code-review-request suppression inert
# across the entire 2026-05-18 sprint.
#
# Test cases:
#   (a) Fresh server passes through — bus_emit returns ok.
#   (b) Stale server returns error referencing /reload-plugins.
#   (c) Anti-revert grep: server.py contains _SERVER_STARTUP_MTIME +
#       _check_freshness + the call from handle_tools_call.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

assert_not_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) FAIL=$((FAIL+1))
                 FAILED_CASES+=("$name (haystack unexpectedly contains '$needle')") ;;
    *) PASS=$((PASS+1)) ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$ROOT/mcp/claude-wow-server/server.py"

if [ ! -f "$SERVER" ]; then
  echo "mcp-server-stale-detection: SKIP — server not found at $SERVER" >&2
  exit 0
fi

# ---- (a) Fresh-server happy path ----
# Use the canonical mcp-call.sh fixture (it spawns + EOFs immediately, so
# server.py mtime cannot change between startup and the single tools/call).
PA=$(mktemp -d)
mkdir -p "$PA/implementations"
touch "$PA/implementations/.message-bus.jsonl"
REQ_ARGS_A='{"from":"senior-developer-20260521T120000-000001","to":"*","type":"ping"}'
RESP_A=$(CLAUDE_PROJECT_DIR="$PA" bash "$ROOT/tests/fixtures/mcp-call.sh" \
  bus_emit "$REQ_ARGS_A" 2>/dev/null)
assert_contains "a-fresh-server-ok-true" '\"ok\": true' "$RESP_A"
assert_not_contains "a-fresh-server-no-stale-message" "modified on disk after startup" "$RESP_A"
rm -rf "$PA"

# ---- (b) Stale-server returns the error ----
# Copy server.py to a temp location so we can touch it without polluting
# the real source. Launch the server with the request driven through a
# subshell that delays the request until AFTER touch — gives the server
# time to capture _SERVER_STARTUP_MTIME (at import time), then we bump
# the mtime, then send the request.
TB=$(mktemp -d)
cp -R "$ROOT/mcp/claude-wow-server" "$TB/"
SERVER_B="$TB/claude-wow-server/server.py"
PB=$(mktemp -d)
mkdir -p "$PB/implementations"
touch "$PB/implementations/.message-bus.jsonl"
REQ_B=$(jq -cn --arg from "senior-developer-20260521T120000-000002" \
  '{jsonrpc:"2.0", id:1, method:"tools/call",
    params:{name:"bus_emit", arguments:{from:$from, to:"*", type:"ping"}}}')

# Drive: sleep so the server captures startup mtime, then `touch -t` sets
# the source's mtime to 2099 (guaranteed > startup_mtime regardless of
# clock skew or filesystem granularity), then send the request.
# `touch -t` macOS format: [[CC]YY]MMDDhhmm[.ss] — 209912312359 = 2099-12-31 23:59.
RESP_B=$({
  sleep 0.4
  touch -t 209912312359 "$SERVER_B"
  sleep 0.1
  echo "$REQ_B"
} | CLAUDE_PROJECT_DIR="$PB" python3 "$SERVER_B" 2>/dev/null)

assert_contains "b-stale-server-error-modified-msg" \
  "modified on disk after startup" "$RESP_B"
assert_contains "b-stale-server-error-reload-plugins" \
  "/reload-plugins" "$RESP_B"
assert_contains "b-stale-server-error-code-internal" \
  '"code": -32603' "$RESP_B"
assert_not_contains "b-stale-server-no-ok-true" '\"ok\": true' "$RESP_B"
rm -rf "$PB" "$TB"

# ---- (c) Anti-revert: server.py body contains the staleness wiring ----
SERVER_BODY=$(cat "$SERVER")
assert_contains "c-startup-mtime-captured" \
  "_SERVER_STARTUP_MTIME = os.path.getmtime" "$SERVER_BODY"
assert_contains "c-check-freshness-defined" \
  "def _check_freshness()" "$SERVER_BODY"
assert_contains "c-check-freshness-called" \
  "stale_err = _check_freshness()" "$SERVER_BODY"
assert_contains "c-error-text-reload-plugins" \
  "Run /reload-plugins" "$SERVER_BODY"
assert_contains "c-internal-error-code" \
  "-32603" "$SERVER_BODY"

echo "mcp-server-stale-detection: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
