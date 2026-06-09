#!/usr/bin/env bash
# Story 109 — manager-monitor.sh wrapper respawns the python child on non-zero
# exit (Monitor task stays armed for the wrapper's lifetime); a clean rc=0
# child lets the wrapper exit too; SIGTERM triggers the EXIT trap.

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
WRAPPER="$ROOT/scripts/wow-process/manager-monitor.sh"

SPAWNED_PIDS=(); TEST_DIRS=()
cleanup() {
  # story 109: manager-monitor.sh runs `while true; do python3 manager-monitor.py
  # --project $d; ...; done`, respawning its FOREGROUND python child on non-zero
  # exit. So the wrapper (the loop) MUST be killed FIRST — killing the child
  # first makes the still-alive wrapper respawn a new one, which then orphans
  # (reparents to PID 1) when the wrapper is killed. After the wrappers are dead
  # (no more respawns possible), a brief settle lets the last orphaned child
  # appear, then a temp-dir sweep reaps it. (Empirically required — child-first
  # left one orphaned manager-monitor.py per run.)
  for pid in "${SPAWNED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  # poll-until-clean: the wrappers are dead now, so repeatedly sweep the temp
  # dirs (a respawn can be reparented/mid-fork past a single sweep) until no
  # process referencing any fixture dir remains (bounded ~3s). $d is a unique
  # mktemp dir, so this can never touch a real/other-project daemon.
  local _i _d _left
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    for _d in "${TEST_DIRS[@]:-}"; do
      [ -n "$_d" ] || continue
      pkill -f "$_d" 2>/dev/null || true
    done
    sleep 0.25
    _left=
    for _d in "${TEST_DIRS[@]:-}"; do
      [ -n "$_d" ] || continue
      pgrep -f "$_d" >/dev/null 2>&1 && _left=1
    done
    [ -z "$_left" ] && break
  done
}
trap cleanup EXIT INT TERM

# mk_project_with_stub <python-exit-code-or-loop>
# Sets up a project dir + a stub manager-monitor.py shimmed into the wrapper's
# SCRIPT_DIR. Returns (echoes) the project dir.
mk_project_with_stub() {
  local exit_mode="$1"  # "exit-N" | "sleep-forever"
  local d
  d=$(mktemp -d)
  TEST_DIRS+=("$d")
  mkdir -p "$d/implementations/.wow-process" "$d/wow-process"
  # The wrapper's SCRIPT_DIR comes from `dirname "$0"`. We invoke the wrapper
  # via a copy in $d/wow-process so the stub lives alongside it.
  cp "$WRAPPER" "$d/wow-process/manager-monitor.sh"
  chmod +x "$d/wow-process/manager-monitor.sh"
  case "$exit_mode" in
    exit-1)
      cat > "$d/wow-process/manager-monitor.py" <<'EOF'
import sys, time
time.sleep(0.3)
sys.exit(1)
EOF
      ;;
    exit-0)
      cat > "$d/wow-process/manager-monitor.py" <<'EOF'
import sys
sys.exit(0)
EOF
      ;;
    sleep-forever)
      cat > "$d/wow-process/manager-monitor.py" <<'EOF'
import time
while True:
  time.sleep(1)
EOF
      ;;
  esac
  echo "$d"
}

# ---- Case (a): crashing child → wrapper respawns + activity-log entry ----
PA=$(mk_project_with_stub exit-1)
TEST_DIRS+=("$PA")   # mk_project_with_stub runs in a $(...) subshell, so its own TEST_DIRS+= is lost — append in the parent
CLAUDE_PROJECT_DIR="$PA" WOW_ROLE="manager" bash "$PA/wow-process/manager-monitor.sh" >/dev/null 2>&1 &
BG_A=$!
SPAWNED_PIDS+=("$BG_A")
sleep 2.5
# After 2.5s with each cycle = sleep 0.3 (child) + sleep 1 (pacing) ≈ 1.3s,
# we expect ≥1 respawn. The wrapper should still be alive.
if kill -0 "$BG_A" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("a-wrapper-still-alive (BG_A=$BG_A died)")
fi
PIDFILE_A="$PA/implementations/.wow-process/manager-monitor-manager.pid"
if [ -f "$PIDFILE_A" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("a-pidfile-present (missing $PIDFILE_A)")
fi
ACT_A=$(cat "$PA/implementations/.activity.jsonl" 2>/dev/null)
assert_contains "a-respawn-logged-type" '"type":"manager-monitor-child-respawn"' "$ACT_A"
assert_contains "a-respawn-logged-rc"   '"child_exit_code":1'                "$ACT_A"
# Clean up.
kill -TERM "$BG_A" 2>/dev/null || true
sleep 1
kill -KILL "$BG_A" 2>/dev/null || true
rm -rf "$PA"

# ---- Case (b): clean child exit (rc=0) → wrapper exits too ----
PB=$(mk_project_with_stub exit-0)
TEST_DIRS+=("$PB")
CLAUDE_PROJECT_DIR="$PB" WOW_ROLE="manager" bash "$PB/wow-process/manager-monitor.sh" >/dev/null 2>&1 &
BG_B=$!
SPAWNED_PIDS+=("$BG_B")
sleep 1.5
if ! kill -0 "$BG_B" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("b-wrapper-exited-on-clean-child (BG_B still alive)")
fi
# PID file should be removed (EXIT trap fired).
PIDFILE_B="$PB/implementations/.wow-process/manager-monitor-manager.pid"
if [ ! -f "$PIDFILE_B" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("b-pidfile-cleaned-on-clean-exit (pidfile remained)")
fi
rm -rf "$PB"

# ---- Case (c): SIGTERM during long-running child → clean shutdown ----
PC=$(mk_project_with_stub sleep-forever)
TEST_DIRS+=("$PC")
CLAUDE_PROJECT_DIR="$PC" WOW_ROLE="manager" bash "$PC/wow-process/manager-monitor.sh" >/dev/null 2>&1 &
BG_C=$!
SPAWNED_PIDS+=("$BG_C")
sleep 1
PIDFILE_C="$PC/implementations/.wow-process/manager-monitor-manager.pid"
if [ -f "$PIDFILE_C" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("c-pidfile-present-pre-sigterm (missing $PIDFILE_C)")
fi
# Signal the python child too (Monitor tool stops via pgroup in production;
# a bare SIGTERM to the wrapper bash doesn't auto-forward to its FG child).
PY_C=$(pgrep -P "$BG_C" 2>/dev/null | head -1)
[ -n "$PY_C" ] && kill -TERM "$PY_C" 2>/dev/null
kill -TERM "$BG_C" 2>/dev/null || true
sleep 1.5
kill -KILL "$BG_C" 2>/dev/null || true
[ -n "$PY_C" ] && kill -KILL "$PY_C" 2>/dev/null
sleep 0.5
if [ ! -f "$PIDFILE_C" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("c-pidfile-cleaned-on-sigterm (pidfile remained)")
fi
rm -rf "$PC"

# ---- Case (d): mechanical assertion — wrapper has the respawn loop ----
WRAPPER_BODY=$(cat "$WRAPPER")
assert_contains "d-respawn-loop-present" "while true; do" "$WRAPPER_BODY"
assert_contains "d-respawn-fn-present"   "_idle_log_respawn" "$WRAPPER_BODY"
case "$WRAPPER_BODY" in
  *"exec python3"*) FAIL=$((FAIL+1))
                    FAILED_CASES+=("d-no-exec-python3 (still using exec, not respawn loop)") ;;
  *) PASS=$((PASS+1)) ;;
esac

echo "manager-monitor-watchdog: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
