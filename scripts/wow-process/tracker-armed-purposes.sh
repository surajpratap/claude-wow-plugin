#!/usr/bin/env bash
# tracker-armed-purposes.sh — list purposes the current agent had armed
# pre-compaction (Story 105). Reads .agents/<agent-id>.json and prints each
# `*_task_id` key whose value is a non-null string, one per line, with the
# `_task_id` suffix stripped (so "bus_tail_task_id" => "bus-tail"; the
# underscore-to-dash translation matches the purpose ids in role-process-map).
#
# Exit codes: 0 success (zero or more purposes printed),
#             2 tracker not found / agent id not resolvable,
#             3 role marker missing.

set -u

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Story 133 (FINDING-35/36): resolve role via whats-my-role.sh, NOT the dead
# fixed-path .claude-plugin/current-role file. Marker lives per-claude-PID
# under .claude/.session-role-by-claude-pid/<pid>. $WOW_ROLE_OVERRIDE is a
# test-only knob.
ROLE="${WOW_ROLE_OVERRIDE:-}"
if [ -z "$ROLE" ]; then
  WMR="$(wow-locate scripts/whats-my-role.sh 2>/dev/null || echo "$SCRIPT_DIR/../whats-my-role.sh")"
  ROLE=$(bash "$WMR" whats-my-role 2>/dev/null || true)
fi
[ -n "$ROLE" ] || { echo "[tracker-armed-purposes] role marker not found (no .claude/.session-role-by-claude-pid/<pid> for this session)" >&2; exit 3; }

AGENT_ID="${WOW_AGENT_ID:-}"
if [ -z "$AGENT_ID" ]; then
  AGENT_ID=$(ls -t "${WOW_ROOT}/implementations/.agents/${ROLE}-"*.json 2>/dev/null \
    | head -1 | sed 's|.*/||; s|\.json$||')
fi
if [ -z "$AGENT_ID" ]; then
  echo "[tracker-armed-purposes] could not resolve agent id" >&2
  exit 2
fi

TRACKER="${WOW_ROOT}/implementations/.agents/${AGENT_ID}.json"
if [ ! -f "$TRACKER" ]; then
  echo "[tracker-armed-purposes] tracker not found: $TRACKER" >&2
  exit 2
fi

jq -r '
  to_entries[]
  | select(.key | endswith("_task_id"))
  | select(.value != null and .value != "")
  | .key
  | sub("_task_id$"; "")
  | gsub("_"; "-")
' "$TRACKER" 2>/dev/null

exit 0
