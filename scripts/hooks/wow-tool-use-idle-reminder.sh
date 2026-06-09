#!/usr/bin/env bash
# scripts/hooks/wow-tool-use-idle-reminder.sh — PostToolUse hook.
#
# When the .nothing_to_do idle marker is set and an agent uses a work tool
# (Bash/Read/Write/Edit), surface a reminder steering toward resume_work —
# catching non-prompt work-resumption (Slack-driven, autonomous) that the
# UserPromptSubmit marker-clear (wow-clear-idle-marker.sh) does not cover.
#
# Reminder-only: NEVER clears the marker (Read/Bash legitimately occur during
# M's idle-assessment). Throttle: <= once per marker-episode per session
# (session_id key; episode = the marker's ts). Silent (no stdout, zero
# behaviour change) when the marker is absent or the tool is out of set.
# additionalContext on exit 0 is delivered by CC as a system-reminder beside
# the tool result (empirically verified, CC 2.1.168). Exit 2 is non-blocking
# for PostToolUse, so a hook fault can never block the tool.
set -u

STDIN=$(cat 2>/dev/null || echo "")
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MARKER="${PROJECT_DIR}/implementations/.nothing_to_do"

[ -f "$MARKER" ] || exit 0   # idle marker absent → silent (the common hot path)

TOOL=$(printf '%s' "$STDIN" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in Bash|Read|Write|Edit) ;; *) exit 0 ;; esac   # out-of-set → silent

EPISODE=$(jq -r '.ts // empty' "$MARKER" 2>/dev/null)
[ -n "$EPISODE" ] || EPISODE="present"
KEY=$(printf '%s' "$STDIN" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$KEY" ] || KEY="$PPID"

STATE_DIR="${PROJECT_DIR}/implementations/.tool-use-reminder"
STATE="${STATE_DIR}/${KEY}"
if [ -r "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$EPISODE" ]; then
  exit 0   # already reminded this session for this episode → throttle
fi

REMINDER="⚠ idle marker (.nothing_to_do) is set. If you're back to work: M should call resume_work (peers: ask M to). resume_work clears it."
OUT=$(jq -nc --arg ctx "$REMINDER" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}' 2>/dev/null)
[ -n "$OUT" ] || exit 0   # jq failed → emit nothing, don't record (retry next call)
printf '%s\n' "$OUT"

mkdir -p "$STATE_DIR" 2>/dev/null || true
printf '%s' "$EPISODE" > "$STATE" 2>/dev/null || true
exit 0
