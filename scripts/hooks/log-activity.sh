#!/usr/bin/env bash
# scripts/hooks/log-activity.sh — unified activity-log router.
#
# Replaces Story 058's PostToolUse-only hook + Story 061's set-state-*.sh hooks.
# Registered on 6 hook events; branches on hook_event_name:
#
#   PreToolUse        → {type:"tool", tool:<tool_name>}
#                       (type:"bg-spawn" for a backgrounded Bash — Story 098)
#   UserPromptSubmit  → {type:"prompt_in"}
#   Stop              → {type:"stop", text:<last_assistant_message>}
#   StopFailure       → {type:"stop_failure"}
#   SessionStart      → {type:"session_start"}
#   SessionEnd        → {type:"session_end"}
#
# Schema: {ts, claude_pid, role, type, tool?, text?}
#   type ∈ {tool, bg-spawn, prompt_in, stop, stop_failure, session_start, session_end}
# Path:   ${CLAUDE_PROJECT_DIR}/implementations/.activity.jsonl
# Marker missing → silent skip. Unknown event_name → silent skip.
# Fire-and-forget — exits 0 unconditionally.
#
# Rotation: every 100th call, trim to last 24h if log >= 1000 lines.

set -u

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

STDIN=$(cat 2>/dev/null || echo "")
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOG="${PROJECT_DIR}/implementations/.activity.jsonl"
COUNTER="${PROJECT_DIR}/implementations/.activity-counter"

CLAUDE_PID="$PPID"
MARKER="${PROJECT_DIR}/.claude/.session-role-by-claude-pid/${CLAUDE_PID}"

[ -r "$MARKER" ] || exit 0
ROLE=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null)
[ -n "$ROLE" ] || exit 0

EVENT=$(echo "$STDIN" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ -n "$EVENT" ] || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LINE=""
case "$EVENT" in
  PreToolUse)
    TOOL=$(echo "$STDIN" | jq -r '.tool_name // empty' 2>/dev/null)
    [ -n "$TOOL" ] || exit 0
    # Story 098: a backgrounded Bash is finite background work the peer will
    # stop to await — type it bg-spawn so manager-monitor.py can tell it apart
    # from a genuine idle stop. Every other tool call (incl. foreground Bash
    # and the Monitor tool) stays type:"tool" — the persistent bus-tail
    # Monitor is infra, not awaited work.
    ROWTYPE="tool"
    if [ "$TOOL" = "Bash" ]; then
      BG=$(echo "$STDIN" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
      [ "$BG" = "true" ] && ROWTYPE="bg-spawn"
    fi
    LINE=$(jq -nc --arg ts "$TS" --argjson pid "$CLAUDE_PID" \
      --arg role "$ROLE" --arg type "$ROWTYPE" --arg tool "$TOOL" \
      '{ts:$ts, claude_pid:$pid, role:$role, type:$type, tool:$tool}' 2>/dev/null)
    ;;
  UserPromptSubmit)
    LINE=$(jq -nc --arg ts "$TS" --argjson pid "$CLAUDE_PID" \
      --arg role "$ROLE" --arg type "prompt_in" \
      '{ts:$ts, claude_pid:$pid, role:$role, type:$type}' 2>/dev/null)
    ;;
  Stop)
    TEXT=$(echo "$STDIN" | jq -r '.last_assistant_message // ""' 2>/dev/null)
    LINE=$(jq -nc --arg ts "$TS" --argjson pid "$CLAUDE_PID" \
      --arg role "$ROLE" --arg type "stop" --arg text "$TEXT" \
      '{ts:$ts, claude_pid:$pid, role:$role, type:$type, text:$text}' 2>/dev/null)
    ;;
  StopFailure)
    LINE=$(jq -nc --arg ts "$TS" --argjson pid "$CLAUDE_PID" \
      --arg role "$ROLE" --arg type "stop_failure" \
      '{ts:$ts, claude_pid:$pid, role:$role, type:$type}' 2>/dev/null)
    ;;
  SessionStart)
    LINE=$(jq -nc --arg ts "$TS" --argjson pid "$CLAUDE_PID" \
      --arg role "$ROLE" --arg type "session_start" \
      '{ts:$ts, claude_pid:$pid, role:$role, type:$type}' 2>/dev/null)
    ;;
  SessionEnd)
    LINE=$(jq -nc --arg ts "$TS" --argjson pid "$CLAUDE_PID" \
      --arg role "$ROLE" --arg type "session_end" \
      '{ts:$ts, claude_pid:$pid, role:$role, type:$type}' 2>/dev/null)
    ;;
  *)
    exit 0
    ;;
esac

[ -n "$LINE" ] || exit 0
echo "$LINE" >> "$LOG" 2>/dev/null || exit 0

# Rotation: every 100th call, trim to last 24h if file >= 1000 lines.
N=$(cat "$COUNTER" 2>/dev/null || echo 0)
case "$N" in ''|*[!0-9]*) N=0 ;; esac
N=$((N + 1))
echo "$N" > "$COUNTER" 2>/dev/null || true

if [ "$((N % 100))" -eq 0 ]; then
  LINES=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  case "$LINES" in ''|*[!0-9]*) LINES=0 ;; esac
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
