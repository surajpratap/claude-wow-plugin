#!/usr/bin/env bash
# Story 072 — PostCompact hook. Emits a `compaction-occurred` bus event
# addressed to the current agent so its bus-tail Monitor (if surviving) can
# trigger a mechanical process-restore via post-compact-restore.sh.
#
# Silent exit 0 on every failure path — observability hook, no error
# propagation per Claude Code design.
#
# Sender ID: synthetic `postcompact-hook-<ts>-<6hex>` — passes the MCP
# server's AGENT_ID_RE but is NOT equal to the agent's own ID, so bus-tail's
# self-echo filter (`.from != $id`) doesn't drop the line for the agent.
# Recipient ID: the agent's own ID (read from the session-keyed role marker).

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Session-keyed role marker. PPID = the claude CLI process that
# invoked the hook. Existing hooks (log-activity.sh, check-askuserquestion-
# role.sh) use the same pattern.
CLAUDE_PID="$PPID"
MARKER="${PROJECT_DIR}/.claude/.session-role-by-claude-pid/${CLAUDE_PID}"
[ -r "$MARKER" ] || exit 0
ROLE=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null)
[ -n "$ROLE" ] || exit 0

# Find the most recent agent tracker for this role.
TRACKER=$(ls -t "${PROJECT_DIR}/implementations/.agents/${ROLE}-"*.json 2>/dev/null | head -1)
[ -n "$TRACKER" ] && [ -f "$TRACKER" ] || exit 0

AGENT_ID=$(jq -r '.agent_id // empty' "$TRACKER" 2>/dev/null)
[ -n "$AGENT_ID" ] || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PAYLOAD=$(jq -nc --arg id "$AGENT_ID" --arg role "$ROLE" --arg ts "$TS" \
  '{agent_id: $id, role: $role, ts: $ts}')

SYNTH_TS=$(date -u +%Y%m%dT%H%M%S)
SYNTH_HEX=$(openssl rand -hex 3 2>/dev/null || printf '%06x' $RANDOM)
SYNTH_FROM="postcompact-hook-${SYNTH_TS}-${SYNTH_HEX}"

SERVER="${CLAUDE_PLUGIN_ROOT:-}/mcp/claude-wow-server/server.py"
[ -f "$SERVER" ] || exit 0

python3 "$SERVER" bus_emit \
  --from "$SYNTH_FROM" \
  --to "$AGENT_ID" \
  --type compaction-occurred \
  --payload-json "$PAYLOAD" 2>/dev/null || true

exit 0
