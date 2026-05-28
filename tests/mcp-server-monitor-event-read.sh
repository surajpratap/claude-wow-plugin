#!/usr/bin/env bash
# Story 154 — runtime test for the MCP server's monitor_event_read tool.
#
# Cases:
#   1. Happy path: tool returns {event: "<raw line text>"} for a real file/line.
#   2. Out-of-range line: tool returns {error: "...", event_file, line} (no exception).
#   3. Missing file: tool returns {error: "...", event_file, line}.
#   4. Path-escape attempt: tool returns {error: "outside ..."}.
#   5. monitor-pipe.sh-produced files roundtrip cleanly (uses real wrapper output).

set -u

PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}
assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"
PIPE="$ROOT/scripts/wow-process/monitor-pipe.sh"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations/.monitor-events/bus-tail"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

call_tool() {
  CLAUDE_PROJECT_DIR="$1" bash "$MCP_CALL" monitor_event_read "$2"
}

extract_text() {
  echo "$1" | jq -r '.result.content[0].text // empty'
}

# ── Case 1: happy path
PROJ=$(mk_project)
EVENTS="$PROJ/implementations/.monitor-events/bus-tail/task1.jsonl"
printf 'first\nsecond\nthird\n' > "$EVENTS"
RESP=$(call_tool "$PROJ" '{"event_file":"implementations/.monitor-events/bus-tail/task1.jsonl","line":2}')
TEXT=$(extract_text "$RESP")
PARSED_EVENT=$(echo "$TEXT" | jq -r '.event // empty')
assert_eq "case1: returns line 2" "second" "$PARSED_EVENT"
rm -rf "$PROJ"

# ── Case 2: out-of-range line
PROJ=$(mk_project)
EVENTS="$PROJ/implementations/.monitor-events/bus-tail/task2.jsonl"
printf 'only line\n' > "$EVENTS"
RESP=$(call_tool "$PROJ" '{"event_file":"implementations/.monitor-events/bus-tail/task2.jsonl","line":99}')
TEXT=$(extract_text "$RESP")
PARSED_ERROR=$(echo "$TEXT" | jq -r '.error // empty')
assert_contains "case2: out-of-range returns error" "line out of range" "$PARSED_ERROR"
rm -rf "$PROJ"

# ── Case 3: missing file
PROJ=$(mk_project)
RESP=$(call_tool "$PROJ" '{"event_file":"implementations/.monitor-events/bus-tail/never-existed.jsonl","line":1}')
TEXT=$(extract_text "$RESP")
PARSED_ERROR=$(echo "$TEXT" | jq -r '.error // empty')
assert_contains "case3: missing-file returns error" "does not exist" "$PARSED_ERROR"
rm -rf "$PROJ"

# ── Case 4: path-escape attempt
PROJ=$(mk_project)
RESP=$(call_tool "$PROJ" '{"event_file":"../../../etc/passwd","line":1}')
TEXT=$(extract_text "$RESP")
PARSED_ERROR=$(echo "$TEXT" | jq -r '.error // empty')
assert_contains "case4: path-escape rejected" "outside" "$PARSED_ERROR"
rm -rf "$PROJ"

# ── Case 5: roundtrip with real wrapper output
PROJ=$(mk_project)
printf 'wrapper-line-1\nwrapper-line-2\n' \
  | WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id roundtrip >/dev/null
RESP=$(call_tool "$PROJ" '{"event_file":"implementations/.monitor-events/bus-tail/roundtrip.jsonl","line":1}')
TEXT=$(extract_text "$RESP")
PARSED_EVENT=$(echo "$TEXT" | jq -r '.event // empty')
assert_eq "case5: roundtrip line 1" "wrapper-line-1" "$PARSED_EVENT"
RESP=$(call_tool "$PROJ" '{"event_file":"implementations/.monitor-events/bus-tail/roundtrip.jsonl","line":2}')
TEXT=$(extract_text "$RESP")
PARSED_EVENT=$(echo "$TEXT" | jq -r '.event // empty')
assert_eq "case5: roundtrip line 2" "wrapper-line-2" "$PARSED_EVENT"
rm -rf "$PROJ"

# ── Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
