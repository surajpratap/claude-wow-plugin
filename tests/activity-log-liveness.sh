#!/usr/bin/env bash
# Story 058 — PostToolUse activity log + M-side reader helper.
#
# Three sub-rigs:
#   Cases 1-3: scripts/hooks/log-activity.sh hook, with synthetic stdin +
#              temp ${CLAUDE_PROJECT_DIR} + writable role marker.
#   Cases 4-6: scripts/m-activity-summary.sh reader, with seeded log files.
#   Case 7:    rotation triggers when counter at 100 + log >= 1000 lines.
#   Case 8:    end-to-end producer→consumer round-trip.
#
# Cases:
# 1. Hook: marker present + valid stdin → one line appended with shape
# 2. Hook: marker missing → exit 0, no append (silent skip)
# 3. Hook: stdin malformed → exit 0, no append, stderr warning
# 4. Reader: empty/missing log → all roles null, exit 0
# 5. Reader: log with mixed-role entries → correct per-role last_ts
# 6. Reader: with --since arg → only entries after that timestamp
# 7. Rotation: log >1000 lines + counter at 100 → trimmed to last 24h
# 8. Round-trip: append 3 lines via hook, read back via helper

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

assert_lt() {
  local name="$1"; local actual="$2"; local upper="$3"
  if [ "$actual" -lt "$upper" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected $actual < $upper, but it is not)")
  fi
}

assert_nonempty() {
  local name="$1"; local val="$2"
  if [ -n "$val" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected non-empty, got empty)")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
HOOK="$REPO_ROOT/scripts/hooks/log-activity.sh"
READER="$SOURCE_ROOT/scripts/m-activity-summary.sh"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo "$d"
}

# -----------------------------------------------------------------------------
# Case 1: marker present + valid stdin → one line appended with shape
# -----------------------------------------------------------------------------
P1=$(mk_project)
echo "senior-developer" > "$P1/.claude/.session-role-by-claude-pid/$$"
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | CLAUDE_PROJECT_DIR="$P1" bash "$HOOK"
RC1=$?
LOG1="$P1/implementations/.activity.jsonl"
LINES1=$(wc -l < "$LOG1" 2>/dev/null | tr -d ' ')
assert_eq "case-1-hook-marker-present-rc" "0" "$RC1"
assert_eq "case-1-hook-one-line-appended" "1" "$LINES1"
LINE1=$(cat "$LOG1")
TS1=$(echo "$LINE1" | jq -r '.ts // empty')
TOOL1=$(echo "$LINE1" | jq -r '.tool // empty')
ROLE1=$(echo "$LINE1" | jq -r '.role // empty')
PID1=$(echo "$LINE1" | jq -r '.claude_pid // empty')
assert_nonempty "case-1-hook-line-has-ts" "$TS1"
assert_eq "case-1-hook-line-tool" "Bash" "$TOOL1"
assert_eq "case-1-hook-line-role" "senior-developer" "$ROLE1"
assert_eq "case-1-hook-line-pid-matches" "$$" "$PID1"
rm -rf "$P1"

# -----------------------------------------------------------------------------
# Case 2: marker missing → exit 0, no append (silent skip)
# -----------------------------------------------------------------------------
P2=$(mk_project)
echo '{"tool_name":"Read"}' | CLAUDE_PROJECT_DIR="$P2" bash "$HOOK"
RC2=$?
LOG2="$P2/implementations/.activity.jsonl"
if [ -f "$LOG2" ]; then
  LINES2=$(wc -l < "$LOG2" | tr -d ' ')
else
  LINES2=0
fi
assert_eq "case-2-hook-marker-missing-rc" "0" "$RC2"
assert_eq "case-2-hook-no-append" "0" "$LINES2"
rm -rf "$P2"

# -----------------------------------------------------------------------------
# Case 3: stdin malformed → exit 0, no append, stderr warning
# Capture stderr via file (`2>FILE` ordering matters; `2>&1 >/dev/null`
# dups stderr to the OLD stdout BEFORE stdout is redirected to /dev/null).
# -----------------------------------------------------------------------------
P3=$(mk_project)
echo "tester" > "$P3/.claude/.session-role-by-claude-pid/$$"
STDERR_FILE=$(mktemp)
echo "not valid json" | CLAUDE_PROJECT_DIR="$P3" bash "$HOOK" >/dev/null 2>"$STDERR_FILE"
RC3=$?
STDERR3=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"
LOG3="$P3/implementations/.activity.jsonl"
if [ -f "$LOG3" ]; then
  LINES3=$(wc -l < "$LOG3" | tr -d ' ')
else
  LINES3=0
fi
assert_eq "case-3-hook-malformed-rc" "0" "$RC3"
assert_eq "case-3-hook-malformed-no-append" "0" "$LINES3"
assert_nonempty "case-3-hook-malformed-stderr-warns" "$STDERR3"
rm -rf "$P3"

# -----------------------------------------------------------------------------
# Case 4: reader empty/missing log → all roles null, exit 0
# -----------------------------------------------------------------------------
P4=$(mk_project)
OUT4=$(ROOT="$P4" bash "$READER")
RC4=$?
assert_eq "case-4-reader-empty-rc" "0" "$RC4"
SD4=$(echo "$OUT4" | jq -r '.by_role."senior-developer"')
PP4=$(echo "$OUT4" | jq -r '.by_role."pair-programmer"')
T4=$(echo "$OUT4" | jq -r '.by_role.tester')
M4=$(echo "$OUT4" | jq -r '.by_role.manager')
S4=$(echo "$OUT4" | jq -r '.by_role.slacker')
TOTAL4=$(echo "$OUT4" | jq -r '.total_lines_since')
assert_eq "case-4-reader-empty-sd-null" "null" "$SD4"
assert_eq "case-4-reader-empty-pp-null" "null" "$PP4"
assert_eq "case-4-reader-empty-t-null" "null" "$T4"
assert_eq "case-4-reader-empty-m-null" "null" "$M4"
assert_eq "case-4-reader-empty-s-null" "null" "$S4"
assert_eq "case-4-reader-empty-total-zero" "0" "$TOTAL4"
rm -rf "$P4"

# -----------------------------------------------------------------------------
# Case 5: log with mixed-role entries → correct per-role last_ts
# -----------------------------------------------------------------------------
P5=$(mk_project)
LOG5="$P5/implementations/.activity.jsonl"
{
  echo '{"ts":"2026-05-03T10:40:00Z","claude_pid":111,"role":"senior-developer","tool":"Read"}'
  echo '{"ts":"2026-05-03T10:42:00Z","claude_pid":111,"role":"senior-developer","tool":"Edit"}'
  echo '{"ts":"2026-05-03T10:43:00Z","claude_pid":222,"role":"pair-programmer","tool":"Read"}'
  echo '{"ts":"2026-05-03T10:44:30Z","claude_pid":222,"role":"pair-programmer","tool":"Read"}'
  echo '{"ts":"2026-05-03T10:45:00Z","claude_pid":333,"role":"tester","tool":"Bash"}'
} > "$LOG5"
OUT5=$(ROOT="$P5" bash "$READER" "2026-05-03T10:00:00Z")
SD5=$(echo "$OUT5" | jq -r '.by_role."senior-developer"')
PP5=$(echo "$OUT5" | jq -r '.by_role."pair-programmer"')
T5=$(echo "$OUT5" | jq -r '.by_role.tester')
M5=$(echo "$OUT5" | jq -r '.by_role.manager')
TOTAL5=$(echo "$OUT5" | jq -r '.total_lines_since')
assert_eq "case-5-reader-sd-latest" "2026-05-03T10:42:00Z" "$SD5"
assert_eq "case-5-reader-pp-latest" "2026-05-03T10:44:30Z" "$PP5"
assert_eq "case-5-reader-t-latest" "2026-05-03T10:45:00Z" "$T5"
assert_eq "case-5-reader-m-null" "null" "$M5"
assert_eq "case-5-reader-total-5" "5" "$TOTAL5"
rm -rf "$P5"

# -----------------------------------------------------------------------------
# Case 6: reader with --since arg → only entries after that timestamp
# -----------------------------------------------------------------------------
P6=$(mk_project)
LOG6="$P6/implementations/.activity.jsonl"
{
  echo '{"ts":"2026-05-03T10:40:00Z","claude_pid":111,"role":"senior-developer","tool":"Read"}'
  echo '{"ts":"2026-05-03T10:42:00Z","claude_pid":111,"role":"senior-developer","tool":"Edit"}'
  echo '{"ts":"2026-05-03T10:43:00Z","claude_pid":222,"role":"pair-programmer","tool":"Read"}'
  echo '{"ts":"2026-05-03T10:45:00Z","claude_pid":333,"role":"tester","tool":"Bash"}'
} > "$LOG6"
OUT6=$(ROOT="$P6" bash "$READER" "2026-05-03T10:42:30Z")
SD6=$(echo "$OUT6" | jq -r '.by_role."senior-developer"')
PP6=$(echo "$OUT6" | jq -r '.by_role."pair-programmer"')
T6=$(echo "$OUT6" | jq -r '.by_role.tester')
TOTAL6=$(echo "$OUT6" | jq -r '.total_lines_since')
assert_eq "case-6-since-sd-pre-cutoff-null" "null" "$SD6"
assert_eq "case-6-since-pp-post-cutoff" "2026-05-03T10:43:00Z" "$PP6"
assert_eq "case-6-since-t-post-cutoff" "2026-05-03T10:45:00Z" "$T6"
assert_eq "case-6-since-total-2" "2" "$TOTAL6"
rm -rf "$P6"

# -----------------------------------------------------------------------------
# Case 7: rotation — log >1000 lines + counter at 100 → trimmed
# Seed 1500 entries: 750 with old timestamps (2020-01-01 — pre-cutoff), 750 recent.
# Set counter to 99. Run hook once → counter→100, triggers rotation.
# -----------------------------------------------------------------------------
P7=$(mk_project)
echo "manager" > "$P7/.claude/.session-role-by-claude-pid/$$"
LOG7="$P7/implementations/.activity.jsonl"
COUNTER7="$P7/implementations/.activity-counter"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in $(seq 1 750); do
  echo "{\"ts\":\"2020-01-01T00:00:0$((i%10))Z\",\"claude_pid\":111,\"role\":\"senior-developer\",\"tool\":\"Read\"}"
done > "$LOG7"
for i in $(seq 1 750); do
  echo "{\"ts\":\"$NOW_ISO\",\"claude_pid\":111,\"role\":\"tester\",\"tool\":\"Bash\"}"
done >> "$LOG7"
LINES_BEFORE=$(wc -l < "$LOG7" | tr -d ' ')
echo "99" > "$COUNTER7"
echo '{"tool_name":"Bash"}' | CLAUDE_PROJECT_DIR="$P7" bash "$HOOK"
LINES_AFTER=$(wc -l < "$LOG7" | tr -d ' ')
NEW_COUNTER=$(cat "$COUNTER7")
assert_eq "case-7-rotation-counter-incremented" "100" "$NEW_COUNTER"
assert_lt "case-7-rotation-trimmed-smaller" "$LINES_AFTER" "$LINES_BEFORE"
# After rotation, all old (2020) entries should be gone — only recent + the just-appended one remain (~751)
[ "$LINES_AFTER" -le 800 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-7-rotation-cutoff-effective: lines after = $LINES_AFTER, expected <= 800"); }
rm -rf "$P7"

# -----------------------------------------------------------------------------
# Case 8: round-trip — append 3 lines via hook, read back via helper
# -----------------------------------------------------------------------------
P8=$(mk_project)
echo "senior-developer" > "$P8/.claude/.session-role-by-claude-pid/$$"
for i in 1 2 3; do
  echo "{\"tool_name\":\"Read\"}" | CLAUDE_PROJECT_DIR="$P8" bash "$HOOK"
done
OUT8=$(ROOT="$P8" bash "$READER" "2026-01-01T00:00:00Z")
TOTAL8=$(echo "$OUT8" | jq -r '.total_lines_since')
SD8=$(echo "$OUT8" | jq -r '.by_role."senior-developer"')
assert_eq "case-8-roundtrip-3-lines" "3" "$TOTAL8"
assert_nonempty "case-8-roundtrip-sd-has-ts" "$SD8"
rm -rf "$P8"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "activity-log-liveness: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
