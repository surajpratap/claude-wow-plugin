#!/usr/bin/env bash
# Story 154 — monitor-pipe.sh fcntl.flock serializes concurrent writers.
#
# Two writer processes append to the same task-id file (rare in production
# but defensive). Asserts (a) every emitted line appears exactly once in
# the events file; (b) no partial/interleaved lines (every line ends with
# exactly one '\n' and prefix matches one of the two writers' tags).
#
# Why this matters: macOS lacks flock(1); the wrapper uses Python
# fcntl.flock (see plugin/scripts/run-all-lock.py for the precedent).
# If serialization breaks, this test fires.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPE="$REPO_ROOT/scripts/wow-process/monitor-pipe.sh"

PROJ=$(mktemp -d)
EVENTS="$PROJ/implementations/.monitor-events/bus-tail/concurrent.jsonl"

# ── Case 1: two concurrent writers, 100 lines each, distinct prefixes
WRITER_A=$(mktemp)
WRITER_B=$(mktemp)
for i in $(seq 1 100); do printf 'A-%03d\n' "$i" >> "$WRITER_A"; done
for i in $(seq 1 100); do printf 'B-%03d\n' "$i" >> "$WRITER_B"; done

# Spawn both writers in parallel against the SAME task-id
( cat "$WRITER_A" | WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id concurrent >/dev/null ) &
PID_A=$!
( cat "$WRITER_B" | WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id concurrent >/dev/null ) &
PID_B=$!
wait "$PID_A" "$PID_B"

# Assert total line count is 200
TOTAL=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case1: 200 total lines (no loss, no interleaving)" "200" "$TOTAL"

# Assert each prefix appears exactly 100 times
A_COUNT=$(grep -cE '^A-[0-9]+$' "$EVENTS" || true)
B_COUNT=$(grep -cE '^B-[0-9]+$' "$EVENTS" || true)
assert_eq "case1: writer A wrote all 100 lines" "100" "$A_COUNT"
assert_eq "case1: writer B wrote all 100 lines" "100" "$B_COUNT"

# Assert no malformed lines (every line matches A-NNN or B-NNN exactly)
MALFORMED=$(grep -vE '^[AB]-[0-9]+$' "$EVENTS" | wc -l | tr -d ' ')
assert_eq "case1: no malformed (partial / interleaved) lines" "0" "$MALFORMED"

rm -rf "$PROJ" "$WRITER_A" "$WRITER_B"

# ── Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
