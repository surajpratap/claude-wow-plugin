#!/usr/bin/env bash
# scripts/hooks/wow-remind-resume-work.sh — UserPromptSubmit hook for M.
#
# When .nothing_to_do exists AND the current session is M's, inject a
# reminder via additionalContext that resume_work is available. The LLM
# can otherwise forget to clear the do-not-disturb marker after the user
# starts interacting again.
#
# Fire-and-forget — exits 0 unconditionally on every path.

set -u

# Drain stdin first to avoid SIGPIPE on the writer; we don't parse it.
cat >/dev/null 2>&1 || true

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MARKER="${PROJECT_DIR}/implementations/.nothing_to_do"

# No marker → nothing to inject.
[ -f "$MARKER" ] || exit 0

# Role gate — only M has resume_work.
CLAUDE_PID="$PPID"
ROLE_MARKER="${PROJECT_DIR}/.claude/.session-role-by-claude-pid/${CLAUDE_PID}"
[ -r "$ROLE_MARKER" ] || exit 0
ROLE=$(tr -d '[:space:]' < "$ROLE_MARKER" 2>/dev/null)
[ "$ROLE" = "manager" ] || exit 0

jq -cn --arg ctx "[wow-monitor] No-work mode is currently active (.nothing_to_do marker present). The user just interacted — if this signals back-to-work, call resume_work to clear the marker and re-enable idle-monitor nudges. The tool is idempotent." \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}' 2>/dev/null

exit 0
