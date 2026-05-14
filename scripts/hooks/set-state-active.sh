#!/usr/bin/env bash
# scripts/hooks/set-state-active.sh — UserPromptSubmit hook (Story 061).
#
# Writes {state:"active"} to ${CLAUDE_PROJECT_DIR}/implementations/.actual-state/<role>.jsonl
# when the agent's turn begins. Per claude-code-guide audit (2026-05-04),
# UserPromptSubmit fires BEFORE Claude processes the prompt — correct timing
# for "active" semantic.
#
# Hook is fire-and-forget — exits 0 unconditionally. Marker missing → silent
# skip (this is observability, not enforcement).

set -u

# Defensive PLUGIN_DIR derivation if ${CLAUDE_PLUGIN_ROOT} is unset (Story 060).
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Drain stdin (UserPromptSubmit gives us {prompt, ...}; we don't parse it).
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
LINE=$(jq -cn --arg state "active" --arg ts "$TS" --arg agent_id "$ROLE" \
  '{state:$state, ts:$ts, agent_id:$agent_id}' 2>/dev/null)
[ -z "$LINE" ] && exit 0
echo "$LINE" >> "$STATE_DIR/${ROLE}.jsonl" 2>/dev/null || true

exit 0
