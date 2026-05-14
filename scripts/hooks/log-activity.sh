#!/usr/bin/env bash
# scripts/hooks/log-activity.sh — PostToolUse hook (Story 058 Theme L).
#
# Appends one JSONL line per tool call to .activity.jsonl for M-side
# observability-based liveness. Hook is fire-and-forget — exits 0
# unconditionally on every error path. Observability MUST NOT block tool
# execution.
#
# Schema: {ts, claude_pid, role, tool}
# Path:   ${CLAUDE_PROJECT_DIR}/implementations/.activity.jsonl
# Producer: every WOW agent (M, SD, PP, T, S) per .claude/settings.json
#           PostToolUse hook matching Write|Edit|MultiEdit|Bash|Read|Grep|Glob.
# Consumer: M (primary) via scripts/m-activity-summary.sh.
#
# Marker missing → silent skip (unlike check-askuserquestion-role.sh which
# blocks; this is observability, not enforcement).

set -u

# Story 060 defensive guard — derive plugin root from script location if
# ${CLAUDE_PLUGIN_ROOT} isn't set (legacy config / older Claude Code).
# Currently unused by this script (only ${CLAUDE_PROJECT_DIR} below for the
# log path), but kept for future hook scripts that may need to source
# sibling helpers (e.g. whats-my-role.sh).
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Read stdin once. Claude Code passes {tool_name, tool_input, ...} JSON.
STDIN=$(cat 2>/dev/null || echo "")

# Resolve project dir from env (set by Claude Code) or fallback to cwd.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOG="${PROJECT_DIR}/implementations/.activity.jsonl"
COUNTER="${PROJECT_DIR}/implementations/.activity-counter"

CLAUDE_PID="$PPID"
MARKER="${PROJECT_DIR}/.claude/.session-role-by-claude-pid/${CLAUDE_PID}"

if [ ! -r "$MARKER" ]; then
  exit 0
fi
ROLE=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null)
if [ -z "$ROLE" ]; then
  exit 0
fi

TOOL=$(echo "$STDIN" | jq -r '.tool_name // empty' 2>/dev/null)
if [ -z "$TOOL" ]; then
  echo "log-activity: no tool_name in stdin — skipping" >&2
  exit 0
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LINE=$(jq -nc --arg ts "$TS" --argjson pid "$CLAUDE_PID" --arg role "$ROLE" --arg tool "$TOOL" \
  '{ts:$ts, claude_pid:$pid, role:$role, tool:$tool}' 2>/dev/null)
if [ -z "$LINE" ]; then
  echo "log-activity: jq failed to build line (jq missing or pid not numeric?) — skipping" >&2
  exit 0
fi
echo "$LINE" >> "$LOG" 2>/dev/null || {
  echo "log-activity: append to $LOG failed — skipping" >&2
  exit 0
}

# Story 061: also write {state:"active"} to .actual-state/<role>.jsonl. One
# hook, two jobs — PostToolUse heartbeat refreshes the state-active timestamp
# on every tool call. Same exit-0-unconditional contract.
STATE_DIR="${PROJECT_DIR}/implementations/.actual-state"
mkdir -p "$STATE_DIR" 2>/dev/null && {
  STATE_LINE=$(jq -cn --arg state "active" --arg ts "$TS" --arg agent_id "$ROLE" \
    '{state:$state, ts:$ts, agent_id:$agent_id}' 2>/dev/null)
  [ -n "$STATE_LINE" ] && echo "$STATE_LINE" >> "$STATE_DIR/${ROLE}.jsonl" 2>/dev/null || true
}

# Rotation: every 100th call, trim to last 24h if file >= 1000 lines.
N=$(cat "$COUNTER" 2>/dev/null || echo 0)
case "$N" in
  ''|*[!0-9]*) N=0 ;;
esac
N=$((N + 1))
echo "$N" > "$COUNTER" 2>/dev/null || true

if [ "$((N % 100))" -eq 0 ]; then
  LINES=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  case "$LINES" in
    ''|*[!0-9]*) LINES=0 ;;
  esac
  if [ "$LINES" -ge 1000 ]; then
    CUTOFF=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    if [ -n "$CUTOFF" ]; then
      jq -c --arg cutoff "$CUTOFF" 'select(.ts >= $cutoff)' "$LOG" > "$LOG.tmp" 2>/dev/null \
        && mv "$LOG.tmp" "$LOG" 2>/dev/null \
        || rm -f "$LOG.tmp" 2>/dev/null
    fi
  fi
fi

exit 0
