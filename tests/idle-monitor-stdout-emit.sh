#!/usr/bin/env bash
# Story 076 — idle-monitor emits JSONL to stdout (not to the bus).
#
# Cases:
#   1. idle predicate trips → exactly one JSONL line on stdout with the
#      expected shape; no bus file appends.
#   2. busy predicate → no line emitted within the wait window; no bus
#      file appends.

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

assert_match() {
  local name="$1"; local pattern="$2"; local actual="$3"
  if echo "$actual" | grep -qE "$pattern"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (pattern '$pattern' not in '$actual')")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="$ROOT/scripts/wow-process/idle-monitor.py"

if [ ! -f "$PY" ]; then
  echo "idle-monitor-stdout-emit: SKIP — $PY not found"
  exit 0
fi

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

mk_fixture() {
  local d activity_type
  activity_type="$1"
  d=$(mktemp -d)
  TEST_DIRS+=("$d")
  mkdir -p "$d/.claude-plugin" "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  echo "manager" > "$d/.claude/.session-role-by-claude-pid/$$"
  printf '{"ts":"2026-05-15T00:00:00Z","claude_pid":%d,"role":"manager","type":"%s"}\n' \
    "$$" "$activity_type" > "$d/implementations/.activity.jsonl"
  echo "$d"
}

# ---------------------------------------------------------------------------
# Case 1: idle predicate → exactly one JSONL line; no bus appends.
# ---------------------------------------------------------------------------
P1=$(mk_fixture "stop")
STDOUT1=$(mktemp)
CLAUDE_PROJECT_DIR="$P1" python3 "$PY" > "$STDOUT1" 2>/dev/null &
PY_PID1=$!
SPAWNED_PIDS+=("$PY_PID1")
sleep 3
kill -TERM "$PY_PID1" 2>/dev/null || true
wait "$PY_PID1" 2>/dev/null || true

LINES1=$(wc -l < "$STDOUT1" | tr -d ' ')
assert_eq "case-1-idle-emits-one-line" "1" "$LINES1"

if [ "$LINES1" = "1" ]; then
  LINE=$(head -1 "$STDOUT1")
  TYPE=$(echo "$LINE" | jq -r '.type // empty')
  TO=$(echo "$LINE" | jq -r '.to // empty')
  FROM=$(echo "$LINE" | jq -r '.from // empty')
  PAYLOAD_TYPE=$(echo "$LINE" | jq -r '.payload | type')
  AGENTS_COUNT=$(echo "$LINE" | jq -r '.payload.agents | length')
  assert_eq    "case-1-type"           "all-idle-nudge"      "$TYPE"
  assert_eq    "case-1-to"             "manager-*"           "$TO"
  assert_match "case-1-from-shape"     "^idle-monitor-[0-9]+$" "$FROM"
  assert_eq    "case-1-payload-object" "object"              "$PAYLOAD_TYPE"
  assert_eq    "case-1-agents-count"   "1"                   "$AGENTS_COUNT"
fi

# Critical: no bus appends from the new transport. The bus file may not even
# exist in the fixture; if it does (older test-residue), it stays empty.
BUS_LINES1="0"
if [ -f "$P1/implementations/.message-bus.jsonl" ]; then
  BUS_LINES1=$(wc -l < "$P1/implementations/.message-bus.jsonl" | tr -d ' ')
fi
assert_eq "case-1-no-bus-appends" "0" "$BUS_LINES1"

rm -rf "$P1" "$STDOUT1"

# ---------------------------------------------------------------------------
# Case 2: busy predicate → no JSONL emitted within the wait window.
# ---------------------------------------------------------------------------
P2=$(mk_fixture "tool_use")
STDOUT2=$(mktemp)
CLAUDE_PROJECT_DIR="$P2" python3 "$PY" > "$STDOUT2" 2>/dev/null &
PY_PID2=$!
SPAWNED_PIDS+=("$PY_PID2")
sleep 2
kill -TERM "$PY_PID2" 2>/dev/null || true
wait "$PY_PID2" 2>/dev/null || true

BYTES2=$(wc -c < "$STDOUT2" | tr -d ' ')
assert_eq "case-2-busy-no-emit" "0" "$BYTES2"

BUS_LINES2="0"
if [ -f "$P2/implementations/.message-bus.jsonl" ]; then
  BUS_LINES2=$(wc -l < "$P2/implementations/.message-bus.jsonl" | tr -d ' ')
fi
assert_eq "case-2-no-bus-appends" "0" "$BUS_LINES2"

rm -rf "$P2" "$STDOUT2"

# ---------------------------------------------------------------------------
# Case 3: .nothing_to_do present → no JSONL emitted even if predicate idle.
# ---------------------------------------------------------------------------
P3=$(mk_fixture "stop")
touch "$P3/implementations/.nothing_to_do"
STDOUT3=$(mktemp)
CLAUDE_PROJECT_DIR="$P3" python3 "$PY" > "$STDOUT3" 2>/dev/null &
PY_PID3=$!
SPAWNED_PIDS+=("$PY_PID3")
sleep 2
kill -TERM "$PY_PID3" 2>/dev/null || true
wait "$PY_PID3" 2>/dev/null || true

BYTES3=$(wc -c < "$STDOUT3" | tr -d ' ')
assert_eq "case-3-nothing-to-do-suppresses-emit" "0" "$BYTES3"

rm -rf "$P3" "$STDOUT3"

echo "idle-monitor-stdout-emit: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
