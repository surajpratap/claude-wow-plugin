#!/usr/bin/env bash
# Story 136 (backlog 165) — cross-session orphan sweep for idle-monitor.
#
# Pre-fix: 93 idle-monitor.py orphans accumulated on dev machine over a
# week of resets. Single-PID lock caught only same-session double-spawn.
#
# This test pins the new sweep_project_orphans behaviour:
#   (a) happy path: orphan a python child by SIGKILLing the wrapper;
#       respawn the wrapper; only one python alive afterwards.
#   (b) cross-project scoping: orphans from project A are NOT killed
#       when project B's wrapper respawns. The --project CLI tag
#       added to the python invocation scopes pgrep -f exactly.
#   (c) anti-revert: idle-monitor.sh body still contains the sweep
#       invocation (no future refactor silently removes it).

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
WRAPPER="$ROOT/scripts/wow-process/idle-monitor.sh"

# Track every PID we spawn so the cleanup trap can reap them.
SPAWNED_PIDS=()

cleanup() {
  for pid in "${SPAWNED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  # Belt-and-suspenders: kill any idle-monitor.py whose --project arg
  # references this test's temp dirs (the temp prefixes are unique to
  # this test invocation, so this can't touch unrelated processes).
  for d in "${TEST_DIRS[@]:-}"; do
    [ -n "$d" ] || continue
    pkill -f "idle-monitor\.py.* --project[= ]$d" 2>/dev/null || true
  done
}
TEST_DIRS=()
trap cleanup EXIT INT TERM

# count_pythons_for_project <project_dir>
# Returns the number of idle-monitor.py processes whose argv contains the
# given --project path. pgrep -f -c gives the count directly.
count_pythons_for_project() {
  local p="$1"
  pgrep -f "idle-monitor\.py.* --project[= ]$p" 2>/dev/null | wc -l | tr -d '[:space:]'
}

spawn_wrapper() {
  # spawn_wrapper <project_dir>  ->  echoes the wrapper PID
  local proj="$1"
  CLAUDE_PROJECT_DIR="$proj" WOW_ROLE=manager bash "$WRAPPER" >/dev/null 2>&1 &
  local pid=$!
  SPAWNED_PIDS+=("$pid")
  echo "$pid"
}

# ---- Case (a): happy path — orphan then sweep ----
PA=$(mktemp -d)
TEST_DIRS+=("$PA")

WRAPPER_A1=$(spawn_wrapper "$PA")
sleep 1.5

# Confirm a python child exists for project A.
N_A1=$(count_pythons_for_project "$PA")
assert_eq "a-initial-spawn-one-python" "1" "$N_A1"

# Capture the python PID before we kill the wrapper, then SIGKILL the
# wrapper. The python will be reparented to PPID=1 (orphan) — still alive
# (no parent-death signal handler in idle-monitor.py).
PYPID_A1=$(pgrep -f "idle-monitor\.py.* --project[= ]$PA" | head -1)
kill -KILL "$WRAPPER_A1" 2>/dev/null || true
sleep 0.5

# Confirm orphan state: python still alive after wrapper-kill.
if kill -0 "$PYPID_A1" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("a-orphan-survives-wrapper-kill (python died with wrapper — test premise broken)")
fi

# Spawn the wrapper again for the SAME project. The new wrapper's
# sweep_project_orphans should kill the orphan; then the wrapper spawns
# its own python. Net: exactly one python alive for project A.
WRAPPER_A2=$(spawn_wrapper "$PA")
sleep 1.5

N_A2=$(count_pythons_for_project "$PA")
assert_eq "a-after-respawn-one-python" "1" "$N_A2"

# And the *previous* orphan PID specifically is gone.
if kill -0 "$PYPID_A1" 2>/dev/null; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("a-orphan-killed-by-sweep (orphan PID $PYPID_A1 still alive)")
else
  PASS=$((PASS+1))
fi

# Tear down A's monitor before moving on.
kill -KILL "$WRAPPER_A2" 2>/dev/null || true
pkill -f "idle-monitor\.py.* --project[= ]$PA" 2>/dev/null || true
sleep 0.3

# ---- Case (b): cross-project scoping ----
PB1=$(mktemp -d)
PB2=$(mktemp -d)
TEST_DIRS+=("$PB1" "$PB2")

WRAPPER_B1=$(spawn_wrapper "$PB1")
WRAPPER_B2=$(spawn_wrapper "$PB2")
sleep 1.5

# Both projects have one python each.
N_B1_initial=$(count_pythons_for_project "$PB1")
N_B2_initial=$(count_pythons_for_project "$PB2")
assert_eq "b-initial-B1-one-python" "1" "$N_B1_initial"
assert_eq "b-initial-B2-one-python" "1" "$N_B2_initial"

# SIGKILL both wrappers, leaving both pythons as orphans.
kill -KILL "$WRAPPER_B1" "$WRAPPER_B2" 2>/dev/null || true
sleep 0.5

# Respawn B1's wrapper. Sweep should kill ONLY B1's orphan; B2's orphan
# must remain alive (project-scoped sweep).
WRAPPER_B1_RESPAWN=$(spawn_wrapper "$PB1")
sleep 1.5

N_B1_after=$(count_pythons_for_project "$PB1")
N_B2_after=$(count_pythons_for_project "$PB2")
assert_eq "b-after-B1-respawn-B1-one-python"  "1" "$N_B1_after"
assert_eq "b-after-B1-respawn-B2-still-alive" "1" "$N_B2_after"

# Tear down.
kill -KILL "$WRAPPER_B1_RESPAWN" 2>/dev/null || true
pkill -f "idle-monitor\.py.* --project[= ]$PB1" 2>/dev/null || true
pkill -f "idle-monitor\.py.* --project[= ]$PB2" 2>/dev/null || true
sleep 0.3

# ---- Case (c): anti-revert — the sweep invocation must remain in
# idle-monitor.sh's body. Any future refactor that drops the call fails
# here regardless of how the rest of the script changes.
WRAPPER_BODY=$(cat "$WRAPPER")
assert_contains "c-sweep-function-defined"     "sweep_project_orphans()" "$WRAPPER_BODY"
assert_contains "c-sweep-invoked"              $'\nsweep_project_orphans\n' "$WRAPPER_BODY"
assert_contains "c-pgrep-project-match"        'pgrep -f "idle-monitor\.py.* --project' "$WRAPPER_BODY"
assert_contains "c-python-invocation-tagged"   'idle-monitor.py" --project "$PROJECT_DIR"' "$WRAPPER_BODY"

echo "idle-monitor-cross-session-sweep: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
