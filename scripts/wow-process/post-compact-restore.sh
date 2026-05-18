#!/usr/bin/env bash
# Story 072 / extended Story 105 — post-compact process-restore helper.
#
# Reads the agent's tracker JSON to discover which Monitors were actually
# armed pre-compaction (Story 105 — tracker-driven detection; the
# role-process-map serves only as a sanity-check intersection), then for
# each emits one line:
#   ALIVE <purpose> <pid>                                     — PID file alive
#   MISSING\t<purpose>\t<script-path>\t<tracker-field>         — tab-separated
#
# Agent parses the MISSING line, invokes monitor-spec.sh <purpose> for the
# JSON re-arm spec, calls Monitor with that spec, then writes the new
# task_id back via monitor-rearm-record.sh.
#
# If the tracker can't be resolved (tracker-armed-purposes.sh exit 2), this
# script falls back to the legacy role-process-map walk and prints a stderr
# warning — preserves behaviour for agents without a tracker yet.
#
# Exit codes: 0 success, 2 map file missing/unreadable, 3 role marker missing.

set -u

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE_MARKER="${WOW_ROOT}/.claude-plugin/current-role"

if [ ! -f "$ROLE_MARKER" ]; then
  echo "[post-compact-restore] role marker not found: $ROLE_MARKER" >&2
  exit 3
fi

ROLE=$(tr -d '[:space:]' < "$ROLE_MARKER")
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

# Story 105 — tracker-driven detection. Fall back to the role-process-map
# walk when the tracker isn't resolvable (agent hasn't run any Monitors yet).
ARMED=$(bash "$SCRIPT_DIR/tracker-armed-purposes.sh" 2>/dev/null || true)
if [ -z "$ARMED" ]; then
  echo "[post-compact-restore] tracker unreachable — falling back to role-process-map walk" >&2
  ARMED=$(jq -r --arg r "$ROLE" '.[$r] // [] | .[]' "$MAP" 2>/dev/null || true)
fi

WOW_PROCESS_DIR="${WOW_ROOT}/implementations/.wow-process"

for p in $ARMED; do
  # Sanity-check: drop purposes not allowed for this role.
  if ! jq -e --arg r "$ROLE" --arg p "$p" '.[$r] // [] | any(. == $p)' "$MAP" >/dev/null 2>&1; then
    continue
  fi
  PIDFILE="${WOW_PROCESS_DIR}/${p}-${ROLE}.pid"
  if [ -f "$PIDFILE" ]; then
    PID=$(tr -d '[:space:]' < "$PIDFILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      echo "ALIVE $p $PID"
      continue
    fi
  fi
  WRAP="${SCRIPT_DIR}/${p}.sh"
  FIELD="$(echo "$p" | tr '-' '_')_task_id"
  printf 'MISSING\t%s\t%s\t%s\n' "$p" "$WRAP" "$FIELD"
done

exit 0
