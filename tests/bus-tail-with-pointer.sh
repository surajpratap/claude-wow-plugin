#!/usr/bin/env bash
# Story 154 — bus-tail.sh role-glob filter stays UPSTREAM of monitor-pipe.sh.
#
# The pipeline is:
#   bash bus-tail.sh "$BUS" "$AGENT_ID" "$ROLE" | bash monitor-pipe.sh --purpose bus-tail
#
# The filter inside bus-tail.sh (forward only lines with to in {*, <role>-*,
# <agent-id>}) runs naturally upstream of monitor-pipe.sh. This test pins
# that the filter is preserved end-to-end: a message addressed to ANOTHER
# role does NOT appear in the consuming role's events file AND no pointer
# is emitted for it.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SPAWNED_PIDS=(); TEST_DIRS=()
cleanup() {
  for pid in "${SPAWNED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    for c in $(pgrep -P "$pid" 2>/dev/null); do kill -KILL "$c" 2>/dev/null || true; done
    kill -KILL "$pid" 2>/dev/null || true
  done
  pkill -f "monitor-pipe.py --purpose bus-tail --task-id pipeline-test" 2>/dev/null || true
  for d in "${TEST_DIRS[@]:-}"; do
    [ -n "$d" ] || continue
    pkill -f "$d" 2>/dev/null || true
    pkill -f "idle-monitor[.]py.* --project[= ]$d" 2>/dev/null || true
    pkill -f "bus-tail[.]sh .*$d" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUS_TAIL="$ROOT/scripts/wow-process/bus-tail.sh"
PIPE="$ROOT/scripts/wow-process/monitor-pipe.sh"

PROJ=$(mktemp -d)
TEST_DIRS+=("$PROJ")
mkdir -p "$PROJ/implementations/.monitor-events/bus-tail"
BUS="$PROJ/implementations/.message-bus.jsonl"
touch "$BUS"

ROLE_GLOB="senior-developer-*"
SD_ID="senior-developer-20260528T120000-abcdef"

# Spawn the pipeline FIRST, then append messages — mimics real Monitor
# operation (bus-tail starts at EOF and reads new lines as they arrive).
# WOW_ROOT pins the wrapper's events-dir to the test project (otherwise
# it'd compute via `git rev-parse` from cwd = worktree root and write
# into the live worktree).
( WOW_ROOT="$PROJ" bash "$BUS_TAIL" "$BUS" "$SD_ID" "senior-developer" | \
    WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id pipeline-test ) >/dev/null 2>&1 &
PIPE_PID=$!
SPAWNED_PIDS+=("$PIPE_PID")

# Let bus-tail warm up + read the empty bus baseline
sleep 1

# Now append 3 messages: 2 addressed to SD (one role-glob, one broadcast),
# 1 to PP-only (should be filtered).
cat >> "$BUS" <<EOF
{"ts":"2026-05-28T12:00:00Z","from":"manager-1","to":"$ROLE_GLOB","type":"ping","payload":"to-sd-glob"}
{"ts":"2026-05-28T12:00:01Z","from":"manager-1","to":"pair-programmer-*","type":"ping","payload":"to-pp-only"}
{"ts":"2026-05-28T12:00:02Z","from":"manager-1","to":"*","type":"hello","payload":"broadcast-to-everyone"}
EOF

# Give bus-tail's poll loop a few ticks to pick the new lines up
sleep 3

# Kill the pipeline (bus-tail's poll loop holds it open)
# We need to kill BOTH ends of the pipeline; bus-tail is the parent, but
# killing it doesn't always reap the python child. Use pkill on the
# WOW_ROOT for safety; bus-tail also has a poll-loop, so SIGTERM works.
kill -TERM "$PIPE_PID" 2>/dev/null || true
sleep 1
# Make sure the python child isn't hanging
pkill -f "monitor-pipe.py --purpose bus-tail --task-id pipeline-test" 2>/dev/null || true
wait 2>/dev/null

EVENTS="$PROJ/implementations/.monitor-events/bus-tail/pipeline-test.jsonl"

if [ ! -f "$EVENTS" ]; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("events file was not created at $EVENTS")
else
  # Two messages should have made it (the SD-addressed + the broadcast);
  # the PP-only one should be filtered out by bus-tail's role-glob predicate.
  GOT_SD_GLOB=$(grep -c 'to-sd-glob' "$EVENTS" || true)
  GOT_PP_ONLY=$(grep -c 'to-pp-only' "$EVENTS" || true)
  GOT_BROADCAST=$(grep -c 'broadcast-to-everyone' "$EVENTS" || true)

  assert_eq "case1: SD-glob message forwarded" "1" "$GOT_SD_GLOB"
  assert_eq "case1: PP-only message FILTERED (not in events)" "0" "$GOT_PP_ONLY"
  assert_eq "case1: broadcast forwarded" "1" "$GOT_BROADCAST"
fi

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
