#!/usr/bin/env bash
# idle-monitor.sh — wrap idle-monitor.py with PID uniqueness.
#
# Started by M at session start as a Monitor-tool task. Single-instance per
# CLAUDE_PROJECT_DIR — if a previous monitor is still alive, exit silently
# rather than spawning a duplicate.
#
# Usage: idle-monitor.sh
#   (Reads ${CLAUDE_PROJECT_DIR} from env; optional ${WOW_ROLE}, defaults
#    to "manager" to mirror the github-bridge.sh convention.)
#
# Story 105: PID file moved from ${PROJECT_DIR}/implementations/.agents/
# idle-monitor.pid to ${WOW_PROCESS_DIR}/idle-monitor-${WOW_ROLE}.pid — the
# bus-tail.sh / github-bridge.sh per-role convention — so post-compact-
# restore.sh / post-compact-rearm-verify.sh land on the same path.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
WOW_ROLE="${WOW_ROLE:-manager}"
WOW_PROCESS_DIR="${PROJECT_DIR}/implementations/.wow-process"
mkdir -p "$WOW_PROCESS_DIR" 2>/dev/null || true
SELF_LOCK="${WOW_PROCESS_DIR}/idle-monitor-${WOW_ROLE}.pid"

# Story 136 (backlog 165): cross-session orphan sweep. The single-PID lock
# below only catches a *second concurrent spawn within one session*; it
# misses prior-session orphans whose wrapper was SIGKILL'd without firing
# its EXIT trap (M found 93 such orphans on 2026-05-19 — accumulated
# across resets/plugin versions). Sweep is scoped to THIS project via the
# --project CLI tag added to the python invocation below, so other
# projects' monitors are never touched.
sweep_project_orphans() {
  local pids
  pids=$(pgrep -f "idle-monitor\.py.* --project[= ]$PROJECT_DIR" 2>/dev/null | grep -v "^$$\$" || true)
  [ -z "$pids" ] && return 0
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  sleep 0.3
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null || true
  return 0
}
sweep_project_orphans

if [ -r "$SELF_LOCK" ]; then
  OLD_PID=$(cat "$SELF_LOCK" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[idle-monitor] already running as PID $OLD_PID — exiting" >&2
    exit 0
  fi
fi

echo "$$" > "$SELF_LOCK"

trap 'rm -f "$SELF_LOCK" 2>/dev/null || true' EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Story 109: respawn the python child on a non-zero exit so the Monitor task
# stays armed for the wrapper's lifetime. Clean exit (rc=0) lets the wrapper
# exit too; SIGINT/SIGTERM trigger the EXIT trap above. A `sleep 1` paces a
# persistent crash so the loop is gentler than tight-loop.
_idle_log_respawn() {
  local rc="$1"
  [ -n "${PROJECT_DIR:-}" ] || return
  local activity="${PROJECT_DIR}/implementations/.activity.jsonl"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","role":"%s","type":"idle-monitor-child-respawn","child_exit_code":%s}\n' \
    "$ts" "${WOW_ROLE:-manager}" "$rc" >> "$activity" 2>/dev/null || true
}

while true; do
  # --project tag is the process-table marker the sweep_project_orphans
  # function (above) matches via pgrep -f. The python script ignores
  # unknown CLI args (no argparse — it only checks `if "--check-predicate"
  # in sys.argv:` for early-return), so --project is silently accepted.
  python3 "$SCRIPT_DIR/idle-monitor.py" --project "$PROJECT_DIR"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    break
  fi
  _idle_log_respawn "$rc" 2>/dev/null || true
  sleep 1
done
