#!/usr/bin/env bash
# scripts/hooks/set-state-chilling.sh — Stop hook (Story 061).
#
# Writes {state:"chilling"} to ${CLAUDE_PROJECT_DIR}/implementations/.actual-state/<role>.jsonl
# when Claude finishes responding (turn-end). Per claude-code-guide audit
# (2026-05-04), Stop fires when the model finishes the turn — distinct from
# SessionEnd which fires at session termination.
#
# Hook is fire-and-forget — exits 0 unconditionally. Marker missing → silent
# skip (this is observability, not enforcement).

set -u

# Defensive PLUGIN_DIR derivation if ${CLAUDE_PLUGIN_ROOT} is unset (Story 060).
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Drain stdin (Stop gives us {stop_hook_active, last_assistant_message, ...};
# we don't parse it).
cat >/dev/null 2>&1 || true

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CLAUDE_PID="$PPID"
MARKER="${PROJECT_DIR}/.claude/.session-role-by-claude-pid/${CLAUDE_PID}"

if [ ! -r "$MARKER" ]; then
  exit 0
fi
ROLE=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null)
if [ -z "$ROLE" ]; then
  exit 0
fi

STATE_DIR="${PROJECT_DIR}/implementations/.actual-state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LINE=$(jq -cn --arg state "chilling" --arg ts "$TS" --arg agent_id "$ROLE" \
  '{state:$state, ts:$ts, agent_id:$agent_id}' 2>/dev/null)
[ -z "$LINE" ] && exit 0
echo "$LINE" >> "$STATE_DIR/${ROLE}.jsonl" 2>/dev/null || true

exit 0
