#!/usr/bin/env bash
# Story 154 — monitor-events-trim.sh drop conditions.
#
# Three drop conditions to pin:
#   (a) file mtime >24h → drop (hard mtime gate).
#   (b) tracker-orphan + mtime >1h → drop (orphan-grace gate).
#   (c) tracker-orphan + mtime <1h → retain (within grace).
#
# Plus regression checks:
#   - file mtime <24h AND task-id present in tracker → retain.
#   - empty events dir → silent no-op exit 0.
#   - missing events dir → silent no-op exit 0.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIM="$ROOT/scripts/wow-process/monitor-events-trim.sh"

mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/implementations/.monitor-events/bus-tail" "$d/implementations/.agents"
  echo "$d"
}

# ── Case 1: file mtime > 24h → dropped (hard mtime gate)
PROJ=$(mk_project)
F25="$PROJ/implementations/.monitor-events/bus-tail/old-task.jsonl"
echo "data" > "$F25"
# Use touch -t to set mtime to 25 hours ago — BSD touch CC format YYYYMMDDhhmm
PAST=$(python3 -c "import time; print(time.strftime('%Y%m%d%H%M', time.localtime(time.time() - 25*3600)))")
touch -t "$PAST" "$F25"
WOW_ROOT="$PROJ" bash "$TRIM"
assert_eq "case1: 25h-old file dropped (hard mtime gate)" "no" "$([ -f "$F25" ] && echo yes || echo no)"
rm -rf "$PROJ"

# ── Case 2: file mtime ~23h (under 24h) AND tracker-orphan → KEPT (mtime gate doesn't fire; orphan-grace doesn't fire if file is recent enough... but our orphan-grace is 1h not 23h)
# Wait — at 23h old AND orphan, both gates: hard mtime is 24h (not yet);
# orphan-grace is 1h (way past). So actually 23h-old orphan IS dropped
# by orphan-grace. Let me redesign this case to test the "retained" path:
# 23h-old file with task-id IN tracker → retained (hard mtime not yet,
# orphan-grace N/A).
PROJ=$(mk_project)
F23="$PROJ/implementations/.monitor-events/bus-tail/keep-this.jsonl"
echo "data" > "$F23"
PAST=$(python3 -c "import time; print(time.strftime('%Y%m%d%H%M', time.localtime(time.time() - 23*3600)))")
touch -t "$PAST" "$F23"
# Add a tracker that references "keep-this" as a task-id
cat > "$PROJ/implementations/.agents/some-agent.json" <<EOF
{"last_line": 0, "bus_tail_task_id": "keep-this"}
EOF
WOW_ROOT="$PROJ" bash "$TRIM"
assert_eq "case2: 23h file with live task-id retained" "yes" "$([ -f "$F23" ] && echo yes || echo no)"
rm -rf "$PROJ"

# ── Case 3: tracker-orphan + mtime > 1h → dropped (orphan-grace gate)
PROJ=$(mk_project)
F2="$PROJ/implementations/.monitor-events/bus-tail/orphan-task.jsonl"
echo "data" > "$F2"
PAST=$(python3 -c "import time; print(time.strftime('%Y%m%d%H%M', time.localtime(time.time() - 2*3600)))")
touch -t "$PAST" "$F2"
# No tracker file references "orphan-task" → orphan
WOW_ROOT="$PROJ" bash "$TRIM"
assert_eq "case3: orphan-after-grace dropped" "no" "$([ -f "$F2" ] && echo yes || echo no)"
rm -rf "$PROJ"

# ── Case 4: tracker-orphan + mtime < 1h → retained (within orphan grace)
PROJ=$(mk_project)
F4="$PROJ/implementations/.monitor-events/bus-tail/fresh-orphan.jsonl"
echo "data" > "$F4"
# Fresh (default mtime — now) — orphan but within grace
WOW_ROOT="$PROJ" bash "$TRIM"
assert_eq "case4: fresh orphan retained (within 1h grace)" "yes" "$([ -f "$F4" ] && echo yes || echo no)"
rm -rf "$PROJ"

# ── Case 5: empty events dir → silent no-op
PROJ=$(mk_project)
WOW_ROOT="$PROJ" bash "$TRIM"
RC=$?
assert_eq "case5: empty dir → exit 0" "0" "$RC"
rm -rf "$PROJ"

# ── Case 6: missing events dir → silent no-op
PROJ=$(mktemp -d)
WOW_ROOT="$PROJ" bash "$TRIM"
RC=$?
assert_eq "case6: missing dir → exit 0" "0" "$RC"
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
