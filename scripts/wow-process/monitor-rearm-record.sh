#!/usr/bin/env bash
# monitor-rearm-record.sh — write a re-armed Monitor's new task_id back to
# the agent's tracker JSON so stale task_id references rot away (Story 105).
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
ROLE_MARKER="${WOW_ROOT}/.claude-plugin/current-role"
[ -f "$ROLE_MARKER" ] || { echo "[monitor-rearm-record] role marker not found" >&2; exit 3; }
ROLE=$(tr -d '[:space:]' < "$ROLE_MARKER")

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
