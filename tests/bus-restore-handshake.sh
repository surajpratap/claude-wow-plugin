#!/usr/bin/env bash
# Story 024 — bus-restored handshake / fast-forward cursor regression test.
#
# Synthesizes a bus + per-agent cursor; invokes scripts/wow-process/bus-tail.sh against it
# briefly; appends a bus-restored line; asserts cursor advances to
# payload.current_line_count without emitting events for the gap.

set -u

SPAWNED_PIDS=(); TEST_DIRS=()
cleanup() {
  for pid in "${SPAWNED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    for c in $(pgrep -P "$pid" 2>/dev/null); do kill -KILL "$c" 2>/dev/null || true; done
    kill -KILL "$pid" 2>/dev/null || true
  done
  for d in "${TEST_DIRS[@]:-}"; do
    [ -n "$d" ] || continue
    pkill -f "$d" 2>/dev/null || true
    pkill -f "idle-monitor[.]py.* --project[= ]$d" 2>/dev/null || true
    pkill -f "bus-tail[.]sh .*$d" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_BUS_TAIL="$REPO_ROOT/scripts/wow-process/bus-tail.sh"
SCRIPT_RESTORE="$REPO_ROOT/scripts/wow-bus-restore.sh"
[ -x "$SCRIPT_BUS_TAIL" ] || { echo "ERROR: $SCRIPT_BUS_TAIL not executable" >&2; exit 2; }
[ -x "$SCRIPT_RESTORE" ] || { echo "ERROR: $SCRIPT_RESTORE not executable" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Per-case helpers
# -----------------------------------------------------------------------------

mk_fixture() {
  local dir; dir=$(mktemp -d)
  TEST_DIRS+=("$dir")
  mkdir -p "$dir/implementations/.agents"
  : > "$dir/implementations/.message-bus.jsonl"
  echo "$dir"
}

write_bus_lines() {
  local dir="$1"; shift
  for line in "$@"; do
    printf '%s\n' "$line" >> "$dir/implementations/.message-bus.jsonl"
  done
}

# Run bus-tail.sh briefly, capture stdout to a file, kill after a short period.
run_bus_tail() {
  local dir="$1" agent_id="$2" role="$3" out="$4"
  local bus="$dir/implementations/.message-bus.jsonl"
  BUS_TAIL_POLL_MS=100 bash "$SCRIPT_BUS_TAIL" "$bus" "$agent_id" "$role" > "$out" 2>/dev/null &
  local pid=$!
  SPAWNED_PIDS+=("$pid")
  sleep 0.5
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
}

# Get current cursor value
get_cursor() {
  local dir="$1" agent_id="$2"
  cat "$dir/implementations/.agents/$agent_id.bus-tail-cursor" 2>/dev/null | tr -d ' \n' || echo "0"
}

# Pre-seed cursor
set_cursor() {
  local dir="$1" agent_id="$2" value="$3"
  printf '%s\n' "$value" > "$dir/implementations/.agents/$agent_id.bus-tail-cursor"
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: bus-restored at end of bus advances cursor past current emitted point.
DIR=$(mk_fixture)
AGENT_ID="senior-developer-test-001"
# Pre-seed bus with 3 lines (none addressed to me) + 1 bus-restored to *
write_bus_lines "$DIR" \
  '{"ts":"t1","from":"x","to":"manager-*","type":"status"}' \
  '{"ts":"t2","from":"y","to":"manager-*","type":"status"}' \
  '{"ts":"t3","from":"z","to":"manager-*","type":"status"}' \
  '{"ts":"t4","from":"manager-test","to":"*","type":"bus-restored","payload":{"reason":"test","current_line_count":4}}'
# Pre-seed cursor at 0 so bus-tail processes existing lines.
set_cursor "$DIR" "$AGENT_ID" 0
OUT=$(mktemp)
run_bus_tail "$DIR" "$AGENT_ID" "senior-developer" "$OUT"
CURSOR=$(get_cursor "$DIR" "$AGENT_ID")
# Cursor should be at >= 4 (caught up to bus-restored line)
if [ "$CURSOR" -ge 4 ]; then
  assert_eq "case-1-cursor-advanced-to-4-or-more" "ok" "ok"
else
  assert_eq "case-1-cursor-advanced-to-4-or-more" "ok" "cursor=$CURSOR"
fi
# bus-restored line should be in output (it's to: *, addressed to me)
EMITTED_RESTORED=$(grep -c '"type":"bus-restored"' "$OUT" || true)
assert_eq "case-1-bus-restored-itself-emitted" "1" "$EMITTED_RESTORED"
rm -rf "$DIR" "$OUT"

# Case 2: bus-restored with current_line_count matching actual bus length.
# Bus has 5 lines; cursor pre-seeded at 1; bus-restored at line 5 with
# current_line_count=5. Cursor advances to 5; gap lines 2-4 suppressed.
DIR=$(mk_fixture)
AGENT_ID="senior-developer-test-002"
write_bus_lines "$DIR" \
  '{"ts":"t1","from":"x","to":"senior-developer-*","type":"status","payload":"already-seen"}' \
  '{"ts":"t2","from":"y","to":"senior-developer-*","type":"status","payload":"in-gap-A"}' \
  '{"ts":"t3","from":"z","to":"senior-developer-*","type":"status","payload":"in-gap-B"}' \
  '{"ts":"t4","from":"w","to":"senior-developer-*","type":"status","payload":"in-gap-C"}' \
  '{"ts":"t5","from":"manager-test","to":"*","type":"bus-restored","payload":{"reason":"realistic","current_line_count":5}}'
# Cursor pre-seeded at 1 (line 1 already processed externally).
set_cursor "$DIR" "$AGENT_ID" 1
OUT=$(mktemp)
run_bus_tail "$DIR" "$AGENT_ID" "senior-developer" "$OUT"
CURSOR=$(get_cursor "$DIR" "$AGENT_ID")
assert_eq "case-2-cursor-advanced-to-5" "5" "$CURSOR"
# Gap lines 2-4 (in-gap-*) should NOT be emitted; bus-restored itself IS emitted.
GAP_COUNT=$(grep -c '"in-gap-' "$OUT" || true)
assert_eq "case-2-gap-suppressed" "0" "$GAP_COUNT"
rm -rf "$DIR" "$OUT"

# Case 3: wow-bus-restore.sh — no M alive → emits with from: bus-restore-helper-*.
DIR=$(mk_fixture)
write_bus_lines "$DIR" '{"ts":"t1","from":"x","to":"*","type":"hello"}'
( cd "$DIR" && git init --quiet . 2>/dev/null && bash "$SCRIPT_RESTORE" --reason "case-3-test" >/dev/null 2>&1 )
LAST=$(tail -1 "$DIR/implementations/.message-bus.jsonl")
case "$LAST" in
  *'"from":"bus-restore-helper-'*) assert_eq "case-3-helper-emit" "yes" "yes" ;;
  *) assert_eq "case-3-helper-emit" "yes" "no (got: $LAST)" ;;
esac
case "$LAST" in
  *'"type":"bus-restored"'*) assert_eq "case-3-restored-type" "yes" "yes" ;;
  *) assert_eq "case-3-restored-type" "yes" "no" ;;
esac
case "$LAST" in
  *'"current_line_count":1'*) assert_eq "case-3-line-count-1" "yes" "yes" ;;
  *) assert_eq "case-3-line-count-1" "yes" "no" ;;
esac
rm -rf "$DIR"

# Case 4: wow-bus-restore.sh — M alive (recent last_seen) → emits with from: manager-<id>.
DIR=$(mk_fixture)
write_bus_lines "$DIR" '{"ts":"t1","from":"x","to":"*","type":"hello"}'
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$DIR/implementations/.agents/manager-active.json" <<JSON
{"last_line": 1, "last_seen": "$NOW_ISO"}
JSON
( cd "$DIR" && git init --quiet . 2>/dev/null && bash "$SCRIPT_RESTORE" --reason "case-4-test" >/dev/null 2>&1 )
LAST=$(tail -1 "$DIR/implementations/.message-bus.jsonl")
case "$LAST" in
  *'"from":"manager-active"'*) assert_eq "case-4-delegating-emit" "yes" "yes" ;;
  *) assert_eq "case-4-delegating-emit" "yes" "no (got: $LAST)" ;;
esac
rm -rf "$DIR"

# Case 5: bus-restored line itself is emitted (regression guard) — already covered in case 1.
# Verifying explicitly that lines AFTER the bus-restored (within the gap) are NOT emitted.
DIR=$(mk_fixture)
AGENT_ID="senior-developer-test-005"
# Lines 1-3 not addressed to me; line 4 is bus-restored; lines 5-8 simulate the gap.
write_bus_lines "$DIR" \
  '{"ts":"t1","from":"x","to":"manager-*","type":"status"}' \
  '{"ts":"t2","from":"y","to":"manager-*","type":"status"}' \
  '{"ts":"t3","from":"z","to":"manager-*","type":"status"}' \
  '{"ts":"t4","from":"manager-test","to":"*","type":"bus-restored","payload":{"reason":"test","current_line_count":8}}' \
  '{"ts":"t5","from":"x","to":"senior-developer-*","type":"status","payload":"in-gap-1"}' \
  '{"ts":"t6","from":"y","to":"senior-developer-*","type":"status","payload":"in-gap-2"}' \
  '{"ts":"t7","from":"z","to":"senior-developer-*","type":"status","payload":"in-gap-3"}' \
  '{"ts":"t8","from":"a","to":"senior-developer-*","type":"status","payload":"in-gap-4"}'
set_cursor "$DIR" "$AGENT_ID" 0
OUT=$(mktemp)
run_bus_tail "$DIR" "$AGENT_ID" "senior-developer" "$OUT"
GAP_EMITS=$(grep -c '"in-gap-' "$OUT" || true)
assert_eq "case-5-gap-lines-not-emitted" "0" "$GAP_EMITS"
RESTORED_EMITS=$(grep -c '"type":"bus-restored"' "$OUT" || true)
assert_eq "case-5-bus-restored-itself-emitted" "1" "$RESTORED_EMITS"
rm -rf "$DIR" "$OUT"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "bus-restore-handshake: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
