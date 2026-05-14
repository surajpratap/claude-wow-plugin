#!/usr/bin/env bash
# Story 072 — post-compact process-restore helper. Diffs role-process-map.json
# against live PID files for the current role; emits one line per purpose:
#   ALIVE <purpose> <pid>   — PID file exists + PID alive
#   MISSING <purpose>       — no PID file OR PID dead (stale)
#
# Agent parses and re-arms only MISSING purposes via scripts/wow-process/
# <purpose>.sh wrappers (Story 071).
#
# Exit codes: 0 success, 2 map file missing/unreadable, 3 role marker missing.

set -u

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROLE_MARKER="${WOW_ROOT}/.claude-plugin/current-role"

if [ ! -f "$ROLE_MARKER" ]; then
  echo "[post-compact-restore] role marker not found: $ROLE_MARKER" >&2
  exit 3
fi

ROLE=$(cat "$ROLE_MARKER" | tr -d '[:space:]')
if [ -z "$ROLE" ]; then
  echo "[post-compact-restore] role marker empty: $ROLE_MARKER" >&2
  exit 3
fi

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MAP=$(
  ls "${WOW_ROOT}/.claude/scripts/wow-process/role-process-map.json" 2>/dev/null \
  || ls "${WOW_ROOT}/scripts/wow-process/role-process-map.json" 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/role-process-map.json 2>/dev/null | head -1
)

if [ -z "$MAP" ] || [ ! -f "$MAP" ]; then
  echo "[post-compact-restore] role-process-map.json not found" >&2
  exit 2
fi

PURPOSES=$(jq -r --arg r "$ROLE" '.[$r] // [] | .[]' "$MAP" 2>/dev/null || true)
WOW_PROCESS_DIR="${WOW_ROOT}/implementations/.wow-process"

for p in $PURPOSES; do
  PIDFILE="${WOW_PROCESS_DIR}/${p}-${ROLE}.pid"
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      echo "ALIVE $p $PID"
      continue
    fi
  fi
  echo "MISSING $p"
done

exit 0
