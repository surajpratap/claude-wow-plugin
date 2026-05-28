#!/usr/bin/env bash
# monitor-rearm-record.sh — write a re-armed Monitor's new task_id back to
# the agent's tracker JSON so stale task_id references rot away.
#
# Usage: monitor-rearm-record.sh <purpose> <task-id>
#
# Exit codes: 0 success, 1 jq/mv failure, 2 tracker not found, 3 bad args.

set -u

PURPOSE="${1:-}"
TASK_ID="${2:-}"
if [ -z "$PURPOSE" ] || [ -z "$TASK_ID" ]; then
  echo "usage: monitor-rearm-record.sh <purpose> <task-id>" >&2
  exit 3
fi

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Story 133: resolve role via whats-my-role.sh, NOT the dead
# fixed-path .claude-plugin/current-role file. Marker lives per-claude-PID
# under .claude/.session-role-by-claude-pid/<pid>. $WOW_ROLE_OVERRIDE is a
# test-only knob.
ROLE="${WOW_ROLE_OVERRIDE:-}"
if [ -z "$ROLE" ]; then
  WMR="$(wow-locate scripts/whats-my-role.sh 2>/dev/null || echo "$SCRIPT_DIR/../whats-my-role.sh")"
  ROLE=$(bash "$WMR" whats-my-role 2>/dev/null || true)
fi
[ -n "$ROLE" ] || { echo "[monitor-rearm-record] role marker not found (no .claude/.session-role-by-claude-pid/<pid> for this session)" >&2; exit 3; }

AGENT_ID="${WOW_AGENT_ID:-}"
if [ -z "$AGENT_ID" ]; then
  AGENT_ID=$(ls -t "${WOW_ROOT}/implementations/.agents/${ROLE}-"*.json 2>/dev/null \
    | head -1 | sed 's|.*/||; s|\.json$||')
fi
TRACKER="${WOW_ROOT}/implementations/.agents/${AGENT_ID}.json"
[ -f "$TRACKER" ] || { echo "[monitor-rearm-record] tracker not found: $TRACKER" >&2; exit 2; }

FIELD="$(echo "$PURPOSE" | tr '-' '_')_task_id"
jq --arg k "$FIELD" --arg v "$TASK_ID" '.[$k] = $v' "$TRACKER" > "$TRACKER.tmp" \
  && mv "$TRACKER.tmp" "$TRACKER" \
  || { echo "[monitor-rearm-record] tracker write failed for $FIELD=$TASK_ID" >&2; exit 1; }

exit 0
