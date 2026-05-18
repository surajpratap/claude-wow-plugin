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
exec python3 "$SCRIPT_DIR/idle-monitor.py"
