#!/usr/bin/env bash
# Story 149 — bus_emit rejects exact-ID sends to non-live agents.
#
# When `to` is an exact agent ID (matches AGENT_ID_RE; not "*" / not "<role>-*")
# but no implementations/.agents/<to>.json tracker exists, the emit MUST fail
# with a clear error rather than silently appending a message no live agent
# would receive. Globs and broadcast remain unaffected.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations/.agents"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

VALID_FROM="senior-developer-20260527T100000-aaaaaa"
LIVE_PEER="pair-programmer-20260527T200000-bbbbbb"
DEAD_PEER="manager-20260101T000000-ffffff"

# -----------------------------------------------------------------------------
# Case 1: exact ID with NO tracker → JSON-RPC error, no append.
# -----------------------------------------------------------------------------
P1=$(mk_project)
RESP1=$(CLAUDE_PROJECT_DIR="$P1" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$VALID_FROM\",\"type\":\"ping\",\"to\":\"$DEAD_PEER\"}")
ERR1=$(echo "$RESP1" | jq -r '.error.message // empty')
LINES1=$(wc -l < "$P1/implementations/.message-bus.jsonl" | tr -d ' ')
assert_contains "case-1-error-mentions-not-live" "not a live agent"     "$ERR1"
assert_contains "case-1-error-mentions-the-id"   "$DEAD_PEER"           "$ERR1"
assert_contains "case-1-error-suggests-glob"     "role-glob"            "$ERR1"
assert_eq       "case-1-no-append"               "0"                    "$LINES1"
rm -rf "$P1"

# -----------------------------------------------------------------------------
# Case 2: broadcast `*` is unaffected (live-check skipped).
# -----------------------------------------------------------------------------
P2=$(mk_project)
RESP2=$(CLAUDE_PROJECT_DIR="$P2" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$VALID_FROM\",\"type\":\"ping\",\"to\":\"*\"}")
OK2=$(echo "$RESP2" | jq -r '.result.content[0].text // empty' | jq -r '.ok // false')
LINES2=$(wc -l < "$P2/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-2-broadcast-ok"     "true" "$OK2"
assert_eq "case-2-broadcast-append" "1"    "$LINES2"
rm -rf "$P2"

# -----------------------------------------------------------------------------
# Case 3: role-glob `<role>-*` is unaffected.
# -----------------------------------------------------------------------------
P3=$(mk_project)
RESP3=$(CLAUDE_PROJECT_DIR="$P3" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$VALID_FROM\",\"type\":\"ping\",\"to\":\"pair-programmer-*\"}")
OK3=$(echo "$RESP3" | jq -r '.result.content[0].text // empty' | jq -r '.ok // false')
LINES3=$(wc -l < "$P3/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-3-glob-ok"     "true" "$OK3"
assert_eq "case-3-glob-append" "1"    "$LINES3"
rm -rf "$P3"

# -----------------------------------------------------------------------------
# Case 4: exact ID WITH tracker present → accepted (live agent).
# -----------------------------------------------------------------------------
P4=$(mk_project)
echo '{"last_line":0,"last_seen":"2026-05-27T20:00:00Z"}' \
  > "$P4/implementations/.agents/$LIVE_PEER.json"
RESP4=$(CLAUDE_PROJECT_DIR="$P4" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$VALID_FROM\",\"type\":\"ping\",\"to\":\"$LIVE_PEER\"}")
OK4=$(echo "$RESP4" | jq -r '.result.content[0].text // empty' | jq -r '.ok // false')
LINES4=$(wc -l < "$P4/implementations/.message-bus.jsonl" | tr -d ' ')
TO4=$(tail -1 "$P4/implementations/.message-bus.jsonl" | jq -r '.to // empty')
assert_eq "case-4-live-ok"          "true"        "$OK4"
assert_eq "case-4-live-append"      "1"           "$LINES4"
assert_eq "case-4-live-to-preserved" "$LIVE_PEER" "$TO4"
rm -rf "$P4"

echo
echo "bus-emit-rejects-dead-agent-id: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
