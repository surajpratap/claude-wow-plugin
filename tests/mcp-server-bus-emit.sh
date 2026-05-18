#!/usr/bin/env bash
# Story 062 — claude-wow MCP server bus_emit tool.
#
# Spawns the server via stdio JSON-RPC and verifies:
#  1. tools/list returns bus_emit with valid input schema
#  2. tools/call bus_emit (valid) → JSON-RPC success + line appended to bus
#  3. invalid type → JSON-RPC error code, no append
#  4. invalid to format → JSON-RPC error, no append
#  5. payload with apostrophe + multi-line preserved verbatim (Story 051 hygiene roundtrip)
#  6. missing required from → JSON-RPC error

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
SERVER="$ROOT/mcp/claude-wow-server/server.py"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

# -----------------------------------------------------------------------------
# Case 1: tools/list returns bus_emit with valid input schema
# -----------------------------------------------------------------------------
P1=$(mk_project)
RESP1=$(echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | CLAUDE_PROJECT_DIR="$P1" python3 "$SERVER" 2>/dev/null)
N1=$(echo "$RESP1" | jq -r '.result.tools[0].name // empty')
REQ1=$(echo "$RESP1" | jq -c '.result.tools[0].inputSchema.required // []')
assert_eq "case-1-tool-name" "bus_emit" "$N1"
assert_eq "case-1-required-fields" '["from","type","to"]' "$REQ1"
rm -rf "$P1"

# -----------------------------------------------------------------------------
# Case 2: bus_emit valid → JSON-RPC success + line appended
# -----------------------------------------------------------------------------
P2=$(mk_project)
RESP2=$(CLAUDE_PROJECT_DIR="$P2" bash "$MCP_CALL" bus_emit \
  '{"from":"senior-developer-20260507T085221-8884cd","type":"ping","to":"manager-*","payload":{"nonce":"x"}}')
OK2=$(echo "$RESP2" | jq -r '.result.content[0].text // empty' | jq -r '.ok // false')
LINES2=$(wc -l < "$P2/implementations/.message-bus.jsonl" | tr -d ' ')
TYPE2=$(tail -1 "$P2/implementations/.message-bus.jsonl" | jq -r '.type // empty')
assert_eq "case-2-result-ok" "true" "$OK2"
assert_eq "case-2-line-appended" "1" "$LINES2"
assert_eq "case-2-type-roundtrip" "ping" "$TYPE2"
rm -rf "$P2"

# -----------------------------------------------------------------------------
# Case 3: invalid type → JSON-RPC error, no append
# -----------------------------------------------------------------------------
P3=$(mk_project)
RESP3=$(CLAUDE_PROJECT_DIR="$P3" bash "$MCP_CALL" bus_emit \
  '{"from":"senior-developer-20260507T085221-8884cd","type":"BOGUS","to":"*"}')
ERRMSG3=$(echo "$RESP3" | jq -r '.error.message // empty')
LINES3=$(wc -l < "$P3/implementations/.message-bus.jsonl" | tr -d ' ')
assert_contains "case-3-error-mentions-enum" "not in allowed enum" "$ERRMSG3"
assert_eq "case-3-no-append" "0" "$LINES3"
rm -rf "$P3"

# -----------------------------------------------------------------------------
# Case 4: invalid to → JSON-RPC error, no append
# -----------------------------------------------------------------------------
P4=$(mk_project)
RESP4=$(CLAUDE_PROJECT_DIR="$P4" bash "$MCP_CALL" bus_emit \
  '{"from":"senior-developer-20260507T085221-8884cd","type":"ping","to":"weird thing"}')
ERRMSG4=$(echo "$RESP4" | jq -r '.error.message // empty')
LINES4=$(wc -l < "$P4/implementations/.message-bus.jsonl" | tr -d ' ')
assert_contains "case-4-error-mentions-format" "to 'weird thing' invalid" "$ERRMSG4"
assert_eq "case-4-no-append" "0" "$LINES4"
rm -rf "$P4"

# -----------------------------------------------------------------------------
# Case 5: payload with apostrophe + multi-line preserved verbatim
# -----------------------------------------------------------------------------
P5=$(mk_project)
PAYLOAD5='{"summary":"Claude Code'"'"'s `tool` ran","details":["one","two"]}'
RESP5=$(CLAUDE_PROJECT_DIR="$P5" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"senior-developer-20260507T085221-8884cd\",\"type\":\"status\",\"to\":\"*\",\"payload\":$PAYLOAD5}")
SUM5=$(tail -1 "$P5/implementations/.message-bus.jsonl" | jq -r '.payload.summary // empty')
assert_contains "case-5-apostrophe-preserved" "Claude Code's" "$SUM5"
assert_contains "case-5-backtick-preserved" '`tool`' "$SUM5"
rm -rf "$P5"

# -----------------------------------------------------------------------------
# Case 6: missing required from → JSON-RPC error
# -----------------------------------------------------------------------------
P6=$(mk_project)
RESP6=$(CLAUDE_PROJECT_DIR="$P6" bash "$MCP_CALL" bus_emit \
  '{"type":"ping","to":"*"}')
ERRMSG6=$(echo "$RESP6" | jq -r '.error.message // empty')
LINES6=$(wc -l < "$P6/implementations/.message-bus.jsonl" | tr -d ' ')
assert_contains "case-6-error-mentions-from" "missing required field: from" "$ERRMSG6"
assert_eq "case-6-no-append" "0" "$LINES6"
rm -rf "$P6"

# -----------------------------------------------------------------------------
# Case 7 (Story 069 amendment-3; line count updated by Story 101 then Story
# 124): cross-check that a trigger-type emit (story-created) writes 4 lines
# via this suite's fixture path — original + read-token-discipline +
# read-skill + read-learnings (the cumulative additive injects). Dedicated
# auto-inject suites cover each inject in depth; this guard catches a
# regression where the inject branches degrade.
# -----------------------------------------------------------------------------
P7=$(mk_project)
CLAUDE_PROJECT_DIR="$P7" bash "$MCP_CALL" bus_emit \
  '{"from":"senior-developer-20260508T120000-aabbcc","type":"story-created","to":"senior-developer-*","payload":{"ref":"x"}}' >/dev/null
LINES7=$(wc -l < "$P7/implementations/.message-bus.jsonl" | tr -d ' ')
TYPE7_LINE2=$(sed -n '2p' "$P7/implementations/.message-bus.jsonl" | jq -r '.type // empty')
assert_eq "case-7-trigger-emits-4-lines" "4" "$LINES7"
assert_eq "case-7-line2-is-auto-inject"  "read-token-discipline" "$TYPE7_LINE2"
rm -rf "$P7"

# -----------------------------------------------------------------------------
# Case 8 (Story 069 amendment-3): cross-check that a non-trigger type
# (status) does NOT auto-inject — single line, no read-token-discipline tail.
# Regression guard against accidental over-injection.
# -----------------------------------------------------------------------------
P8=$(mk_project)
CLAUDE_PROJECT_DIR="$P8" bash "$MCP_CALL" bus_emit \
  '{"from":"senior-developer-20260508T120000-aabbcc","type":"status","to":"*","payload":{"note":"x"}}' >/dev/null
LINES8=$(wc -l < "$P8/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-8-non-trigger-1-line" "1" "$LINES8"
rm -rf "$P8"

# -----------------------------------------------------------------------------
# Case 9 (Story 087): the 3 retro-flow / sprint types added to ALLOWED_TYPES
# (sprint-ack, retro-opening, retro-close) emit cleanly — no enum rejection.
# -----------------------------------------------------------------------------
for t in sprint-ack retro-opening retro-close; do
  P9=$(mk_project)
  RESP9=$(CLAUDE_PROJECT_DIR="$P9" bash "$MCP_CALL" bus_emit \
    "{\"from\":\"senior-developer-20260507T085221-8884cd\",\"type\":\"$t\",\"to\":\"manager-*\"}")
  OK9=$(echo "$RESP9" | jq -r '.result.content[0].text // empty' | jq -r '.ok // false')
  ERR9=$(echo "$RESP9" | jq -r '.error.message // empty')
  TYPE9=$(tail -1 "$P9/implementations/.message-bus.jsonl" 2>/dev/null | jq -r '.type // empty')
  assert_eq "case-9-$t-result-ok" "true" "$OK9"
  assert_eq "case-9-$t-no-enum-error" "" "$ERR9"
  assert_eq "case-9-$t-type-roundtrip" "$t" "$TYPE9"
  rm -rf "$P9"
done

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "mcp-server-bus-emit: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
