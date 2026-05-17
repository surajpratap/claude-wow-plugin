#!/usr/bin/env bash
# activity-log router schema tests.
#
# Replaces activity-log-liveness.sh. Tests the rewritten log-activity.sh
# router across all 6 hook events:
#   PreToolUse, UserPromptSubmit, Stop, StopFailure, SessionStart, SessionEnd
#
# Sub-rigs:
#   Cases 1-6: one row appended per event with correct {type, ...} shape.
#   Case 7:    marker missing → silent skip (exit 0, no append).
#   Case 8:    unknown hook_event_name → silent skip (exit 0, no append).
#   Case 9:    rotation preserved — counter 100 + log >= 1000 lines → trim.
#   Case 10:   reader (m-activity-summary.sh) still parses new rows.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}
assert_nonempty() {
  local name="$1"; local val="$2"
  if [ -n "$val" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected non-empty)"); fi
}
assert_lt() {
  local name="$1"; local actual="$2"; local upper="$3"
  if [ "$actual" -lt "$upper" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected $actual < $upper)"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/scripts/hooks/log-activity.sh"
READER="$REPO_ROOT/scripts/m-activity-summary.sh"

mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo "$d"
}

run_hook() {
  local proj="$1"; local stdin="$2"
  echo "$stdin" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK"
}

# Case 1: PreToolUse → row with type:tool, tool:<name>
P1=$(mk_project)
echo "senior-developer" > "$P1/.claude/.session-role-by-claude-pid/$$"
run_hook "$P1" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
LOG1="$P1/implementations/.activity.jsonl"
LINE=$(tail -1 "$LOG1")
assert_eq "case-1-pretoolse-type" "tool" "$(jq -r '.type' <<<"$LINE")"
assert_eq "case-1-pretoolse-tool" "Bash" "$(jq -r '.tool' <<<"$LINE")"
assert_eq "case-1-pretoolse-role" "senior-developer" "$(jq -r '.role' <<<"$LINE")"
assert_eq "case-1-pretoolse-pid" "$$" "$(jq -r '.claude_pid' <<<"$LINE")"
assert_nonempty "case-1-pretoolse-ts" "$(jq -r '.ts // empty' <<<"$LINE")"
rm -rf "$P1"

# Case 2: UserPromptSubmit → row with type:prompt_in
P2=$(mk_project)
echo "manager" > "$P2/.claude/.session-role-by-claude-pid/$$"
run_hook "$P2" '{"hook_event_name":"UserPromptSubmit","prompt":"hello"}'
LINE=$(tail -1 "$P2/implementations/.activity.jsonl")
assert_eq "case-2-prompt-in-type" "prompt_in" "$(jq -r '.type' <<<"$LINE")"
assert_eq "case-2-prompt-in-role" "manager" "$(jq -r '.role' <<<"$LINE")"
rm -rf "$P2"

# Case 3: Stop → row with type:stop, text:<last_assistant_message>
P3=$(mk_project)
echo "pair-programmer" > "$P3/.claude/.session-role-by-claude-pid/$$"
run_hook "$P3" '{"hook_event_name":"Stop","last_assistant_message":"All done."}'
LINE=$(tail -1 "$P3/implementations/.activity.jsonl")
assert_eq "case-3-stop-type" "stop" "$(jq -r '.type' <<<"$LINE")"
assert_eq "case-3-stop-text" "All done." "$(jq -r '.text' <<<"$LINE")"
rm -rf "$P3"

# Case 4: StopFailure → row with type:stop_failure
P4=$(mk_project)
echo "tester" > "$P4/.claude/.session-role-by-claude-pid/$$"
run_hook "$P4" '{"hook_event_name":"StopFailure"}'
LINE=$(tail -1 "$P4/implementations/.activity.jsonl")
assert_eq "case-4-stop-failure-type" "stop_failure" "$(jq -r '.type' <<<"$LINE")"
rm -rf "$P4"

# Case 5: SessionStart → row with type:session_start
P5=$(mk_project)
echo "manager" > "$P5/.claude/.session-role-by-claude-pid/$$"
run_hook "$P5" '{"hook_event_name":"SessionStart"}'
LINE=$(tail -1 "$P5/implementations/.activity.jsonl")
assert_eq "case-5-session-start-type" "session_start" "$(jq -r '.type' <<<"$LINE")"
rm -rf "$P5"

# Case 6: SessionEnd → row with type:session_end
P6=$(mk_project)
echo "manager" > "$P6/.claude/.session-role-by-claude-pid/$$"
run_hook "$P6" '{"hook_event_name":"SessionEnd"}'
LINE=$(tail -1 "$P6/implementations/.activity.jsonl")
assert_eq "case-6-session-end-type" "session_end" "$(jq -r '.type' <<<"$LINE")"
rm -rf "$P6"

# Case 7: marker missing → silent skip
P7=$(mk_project)
run_hook "$P7" '{"hook_event_name":"PreToolUse","tool_name":"Read"}'
RC7=$?
LOG7="$P7/implementations/.activity.jsonl"
LINES7=0
[ -f "$LOG7" ] && LINES7=$(wc -l < "$LOG7" | tr -d ' ')
assert_eq "case-7-marker-missing-rc" "0" "$RC7"
assert_eq "case-7-marker-missing-no-append" "0" "$LINES7"
rm -rf "$P7"

# Case 8: unknown hook_event_name → silent skip
P8=$(mk_project)
echo "tester" > "$P8/.claude/.session-role-by-claude-pid/$$"
run_hook "$P8" '{"hook_event_name":"PostCompact"}'
RC8=$?
LOG8="$P8/implementations/.activity.jsonl"
LINES8=0
[ -f "$LOG8" ] && LINES8=$(wc -l < "$LOG8" | tr -d ' ')
assert_eq "case-8-unknown-event-rc" "0" "$RC8"
assert_eq "case-8-unknown-event-no-append" "0" "$LINES8"
rm -rf "$P8"

# Case 9: rotation preserved
P9=$(mk_project)
echo "manager" > "$P9/.claude/.session-role-by-claude-pid/$$"
LOG9="$P9/implementations/.activity.jsonl"
COUNTER9="$P9/implementations/.activity-counter"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in $(seq 1 750); do
  echo "{\"ts\":\"2020-01-01T00:00:0$((i%10))Z\",\"claude_pid\":111,\"role\":\"senior-developer\",\"type\":\"tool\",\"tool\":\"Read\"}"
done > "$LOG9"
for i in $(seq 1 750); do
  echo "{\"ts\":\"$NOW_ISO\",\"claude_pid\":111,\"role\":\"tester\",\"type\":\"tool\",\"tool\":\"Bash\"}"
done >> "$LOG9"
LINES_BEFORE=$(wc -l < "$LOG9" | tr -d ' ')
echo "99" > "$COUNTER9"
run_hook "$P9" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
LINES_AFTER=$(wc -l < "$LOG9" | tr -d ' ')
NEW_COUNTER=$(cat "$COUNTER9")
assert_eq "case-9-rotation-counter-incremented" "100" "$NEW_COUNTER"
assert_lt "case-9-rotation-trimmed-smaller" "$LINES_AFTER" "$LINES_BEFORE"
rm -rf "$P9"

# Case 10: reader compatibility with new schema
P10=$(mk_project)
LOG10="$P10/implementations/.activity.jsonl"
{
  echo '{"ts":"2026-05-14T10:40:00Z","claude_pid":111,"role":"senior-developer","type":"tool","tool":"Read"}'
  echo '{"ts":"2026-05-14T10:42:00Z","claude_pid":111,"role":"senior-developer","type":"stop","text":"done"}'
} > "$LOG10"
OUT10=$(ROOT="$P10" bash "$READER" "2026-05-14T10:00:00Z")
SD10=$(echo "$OUT10" | jq -r '.by_role."senior-developer"')
assert_eq "case-10-reader-sd-latest" "2026-05-14T10:42:00Z" "$SD10"
rm -rf "$P10"

echo
echo "activity-log-schema: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
