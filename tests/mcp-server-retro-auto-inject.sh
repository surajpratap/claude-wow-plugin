#!/usr/bin/env bash
# Story 070 — runtime test for the MCP server's retro-doctrine auto-inject
# in mcp/claude-wow-server/server.py handle_bus_emit.
#
# When called with type IN {review-closed, retro-open} the server writes
# BOTH the original line AND a parallel read-retro-doctrine broadcast in
# a SINGLE f.write() call inside one with-open block. Mirrors the
# token-discipline auto-inject pattern (Story 069 amendment-3).

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
SENDER="manager-20260509T070000-aabbcc"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

# -----------------------------------------------------------------------------
# Case (a): review-closed emits 2 bus lines (original + auto-injected).
# -----------------------------------------------------------------------------
PA=$(mk_project)
CLAUDE_PROJECT_DIR="$PA" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"review-closed\",\"to\":\"manager-*\",\"payload\":{\"sprint_id\":\"s1\"}}" >/dev/null
LINES_A=$(wc -l < "$PA/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-a-review-closed-2-lines" "2" "$LINES_A"
rm -rf "$PA"

# -----------------------------------------------------------------------------
# Case (b): retro-open emits 2 bus lines (original + auto-injected).
# -----------------------------------------------------------------------------
PB=$(mk_project)
CLAUDE_PROJECT_DIR="$PB" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"retro-open\",\"to\":\"*\",\"payload\":{\"sprint_id\":\"s1\"}}" >/dev/null
LINES_B=$(wc -l < "$PB/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-b-retro-open-2-lines" "2" "$LINES_B"
rm -rf "$PB"

# -----------------------------------------------------------------------------
# Case (c): non-trigger type emits 1 line (auto-inject is type-gated).
# -----------------------------------------------------------------------------
PC=$(mk_project)
CLAUDE_PROJECT_DIR="$PC" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"status\",\"to\":\"*\",\"payload\":{\"note\":\"x\"}}" >/dev/null
LINES_C=$(wc -l < "$PC/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-c-status-1-line" "1" "$LINES_C"
rm -rf "$PC"

# -----------------------------------------------------------------------------
# Case (d): auto-injected envelope shape.
# -----------------------------------------------------------------------------
PD=$(mk_project)
CLAUDE_PROJECT_DIR="$PD" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"review-closed\",\"to\":\"manager-*\",\"payload\":{\"sprint_id\":\"s1\"}}" >/dev/null
INJECT_LINE=$(sed -n '2p' "$PD/implementations/.message-bus.jsonl")
INJECT_TYPE=$(echo "$INJECT_LINE" | jq -r '.type // empty')
INJECT_TO=$(echo "$INJECT_LINE" | jq -r '.to // empty')
INJECT_FROM=$(echo "$INJECT_LINE" | jq -r '.from // empty')
INJECT_PATH=$(echo "$INJECT_LINE" | jq -r '.payload.path // empty')
INJECT_REASON=$(echo "$INJECT_LINE" | jq -r '.payload.reason // empty')
assert_eq "case-d1-inject-type"   "read-retro-doctrine"          "$INJECT_TYPE"
assert_eq "case-d2-inject-to"     "*"                            "$INJECT_TO"
assert_eq "case-d3-inject-from"   "$SENDER"                      "$INJECT_FROM"
assert_eq "case-d4-inject-path"   "commands/_retro-doctrine.md"  "$INJECT_PATH"
assert_contains "case-d5-inject-reason-auto" "auto-injected" "$INJECT_REASON"
rm -rf "$PD"

# -----------------------------------------------------------------------------
# Case (e): single-write atomicity under concurrency. 5 parallel review-closed
# emits produce exactly 10 lines AND every read-retro-doctrine line is
# immediately preceded by a review-closed line (no pair interleaving).
# -----------------------------------------------------------------------------
PE=$(mk_project)
for i in 1 2 3 4 5; do
  CLAUDE_PROJECT_DIR="$PE" bash "$MCP_CALL" bus_emit \
    "{\"from\":\"$SENDER\",\"type\":\"review-closed\",\"to\":\"manager-*\",\"payload\":{\"sprint_id\":\"s$i\"}}" >/dev/null &
done
wait
LINES_E=$(wc -l < "$PE/implementations/.message-bus.jsonl" | tr -d ' ')
INTERLEAVED=0
PREV_TYPE=""
while IFS= read -r line; do
  this_type=$(echo "$line" | jq -r '.type // empty')
  if [ "$this_type" = "read-retro-doctrine" ]; then
    if [ "$PREV_TYPE" != "review-closed" ]; then
      INTERLEAVED=$((INTERLEAVED+1))
    fi
  fi
  PREV_TYPE="$this_type"
done < "$PE/implementations/.message-bus.jsonl"
assert_eq "case-e-concurrent-5x-emits-10-lines" "10" "$LINES_E"
assert_eq "case-e-no-interleaving"               "0"  "$INTERLEAVED"
rm -rf "$PE"

# -----------------------------------------------------------------------------
# Case (f): token-discipline auto-inject coexists — story-created still emits
# its own auto-inject (not retro-doctrine). Regression guard against the inject
# branches stepping on each other. Story 124: story-created now writes 4 lines
# (original + read-token-discipline + read-skill + read-learnings); line 2 is
# still the read-token-discipline doctrine inject.
# -----------------------------------------------------------------------------
PF=$(mk_project)
CLAUDE_PROJECT_DIR="$PF" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"senior-developer-20260509T070000-aabbcc\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}" >/dev/null
LINES_F=$(wc -l < "$PF/implementations/.message-bus.jsonl" | tr -d ' ')
INJECT_TYPE_F=$(sed -n '2p' "$PF/implementations/.message-bus.jsonl" | jq -r '.type // empty')
assert_eq "case-f-story-created-emits-4-lines" "4" "$LINES_F"
assert_eq "case-f-story-created-injects-token-discipline" "read-token-discipline" "$INJECT_TYPE_F"
rm -rf "$PF"

echo "mcp-server-retro-auto-inject: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
