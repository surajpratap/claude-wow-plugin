#!/usr/bin/env bash
# Story 154 — monitor-pipe.sh pointer-line shape contract.
#
# Pipes synthetic input through the wrapper; asserts each emitted stdout
# line matches the canonical pointer regex:
#   ^\[monitor:<purpose>\] event #\d+ at .*\.jsonl\. Call `monitor_event_read`.*$
#
# One pointer line per input line; 1-indexed line numbers; pointer well
# under CC Monitor's ~500-char truncation budget.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}
assert_match() {
  local name="$1"; local pattern="$2"; local val="$3"
  if printf '%s' "$val" | grep -qE "$pattern"; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (pattern '$pattern' did not match '$val')"); fi
}
assert_lt() {
  local name="$1"; local actual="$2"; local upper="$3"
  if [ "$actual" -lt "$upper" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected $actual < $upper)"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPE="$REPO_ROOT/scripts/wow-process/monitor-pipe.sh"

# Each test runs in its own temp project (WOW_ROOT override) so the
# events files don't pollute the real repo.
mk_project() {
  local d; d=$(mktemp -d)
  printf "%s" "$d"
}

POINTER_REGEX='^\[monitor:[a-z-]+\] event #[0-9]+ at .*\.jsonl\. Call `monitor_event_read`.*$'

# ── Case 1: 3-line input → 3 pointer lines, regex match, ascending line numbers
PROJ=$(mk_project)
OUT=$(printf 'alpha\nbeta\ngamma\n' \
  | WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id case1tid)
LINE_COUNT=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
assert_eq "case1: 3 pointer lines" "3" "$LINE_COUNT"

L1=$(printf '%s\n' "$OUT" | sed -n '1p')
L2=$(printf '%s\n' "$OUT" | sed -n '2p')
L3=$(printf '%s\n' "$OUT" | sed -n '3p')
assert_match "case1 L1 matches regex" "$POINTER_REGEX" "$L1"
assert_match "case1 L2 matches regex" "$POINTER_REGEX" "$L2"
assert_match "case1 L3 matches regex" "$POINTER_REGEX" "$L3"
assert_match "case1 L1 says event #1" 'event #1 at' "$L1"
assert_match "case1 L2 says event #2" 'event #2 at' "$L2"
assert_match "case1 L3 says event #3" 'event #3 at' "$L3"

# Verify the events file has the verbatim input
EVENTS="$PROJ/implementations/.monitor-events/bus-tail/case1tid.jsonl"
assert_eq "case1: events file exists" "yes" "$([ -f "$EVENTS" ] && echo yes || echo no)"
assert_eq "case1: events file line 1" "alpha" "$(sed -n '1p' "$EVENTS")"
assert_eq "case1: events file line 3" "gamma" "$(sed -n '3p' "$EVENTS")"
rm -rf "$PROJ"

# ── Case 2: pointer length under 500 chars (CC Monitor truncation budget)
PROJ=$(mk_project)
OUT=$(printf 'x\n' | WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id case2tid)
LEN=${#OUT}
assert_lt "case2: pointer under 500 chars" "$LEN" "500"
rm -rf "$PROJ"

# ── Case 3: purpose name appears in pointer prefix exactly
PROJ=$(mk_project)
OUT=$(printf 'y\n' | WOW_ROOT="$PROJ" bash "$PIPE" --purpose github-bridge --task-id case3tid)
assert_match "case3: github-bridge purpose in pointer" '^\[monitor:github-bridge\]' "$OUT"
rm -rf "$PROJ"

# ── Case 4: long input (5000 chars) — the event line goes into the file
#           verbatim, pointer is short
PROJ=$(mk_project)
LONG=$(python3 -c 'print("z" * 5000)')
OUT=$(printf '%s\n' "$LONG" | WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id case4tid)
LEN=${#OUT}
assert_lt "case4: pointer still under 500 chars" "$LEN" "500"
STORED=$(sed -n '1p' "$PROJ/implementations/.monitor-events/bus-tail/case4tid.jsonl")
assert_eq "case4: events file has the full 5000 chars" "5000" "${#STORED}"
rm -rf "$PROJ"

# ── Case 5: --task-id arg overrides $WOW_MONITOR_TASK_ID
PROJ=$(mk_project)
OUT=$(printf 'q\n' | WOW_MONITOR_TASK_ID="env_value" WOW_ROOT="$PROJ" \
  bash "$PIPE" --purpose bus-tail --task-id arg_value)
assert_match "case5: --task-id wins over env" 'arg_value\.jsonl' "$OUT"
rm -rf "$PROJ"

# ── Case 6: env var takes effect when --task-id absent
PROJ=$(mk_project)
OUT=$(printf 'r\n' | WOW_MONITOR_TASK_ID="env_only_id" WOW_ROOT="$PROJ" \
  bash "$PIPE" --purpose bus-tail)
assert_match "case6: env-only id used" 'env_only_id\.jsonl' "$OUT"
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
