#!/usr/bin/env bash
# plugin/scripts/hooks/wow-inject-startup.sh — UserPromptSubmit hook.
# Detects /<role> command-file expansion via the line-1 sentinel and emits an
# additionalContext instruction to Read commands/_<role>-startup.md.
# Fire-and-forget — always exits 0.
set -u

STDIN=$(cat 2>/dev/null || echo "")
EVENT=$(echo "$STDIN" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ "$EVENT" = "UserPromptSubmit" ] || exit 0

PROMPT=$(echo "$STDIN" | jq -r '.prompt // ""' 2>/dev/null)
# Sentinel must land in the first 5 lines of the prompt body.
ROLE=$(echo "$PROMPT" | head -5 | grep -oE 'claude-wow-startup:[[:space:]]*[a-z-]+' | head -1 | awk -F: '{print $2}' | tr -d '[:space:]')
[ -n "$ROLE" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-}"

STARTUP=""
for cand in \
  "$PROJECT_DIR/.claude/commands/_${ROLE}-startup.md" \
  "$PLUGIN_DIR/commands/_${ROLE}-startup.md"; do
  [ -r "$cand" ] && { STARTUP="$cand"; break; }
done
[ -n "$STARTUP" ] || exit 0

MSG="[wow-startup] You are the ${ROLE} role. Read \`${STARTUP}\` now via the Read tool and follow it in full before responding to the user. The startup file is your boot procedure (claim role first, then required reading, setup, peer check, bootstrap)."

jq -cn --arg ctx "$MSG" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}' 2>/dev/null

exit 0
