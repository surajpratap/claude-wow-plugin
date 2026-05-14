#!/usr/bin/env bash
# scripts/hooks/check-askuserquestion-role.sh — PreToolUse hook for AskUserQuestion.
#
# Allows iff session role == "manager" per marker file.
# Per Story 048 + spike doc: hook's $PPID is the Claude session PID directly
# (no parent-chain walk needed in hook context — hook is spawned as direct
# child of Claude Code). Marker is written/cleaned by 049's
# scripts/whats-my-role.sh helper at agent startup/exit.

set -u

# Story 060 defensive guard — derive plugin root from script location if
# ${CLAUDE_PLUGIN_ROOT} isn't set (legacy config / older Claude Code).
# Currently unused by this script (only ${CLAUDE_PROJECT_DIR} below for the
# marker path), but kept for future hook scripts that may need to source
# sibling helpers (e.g. whats-my-role.sh).
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Hook stdin payload is consumed but not parsed (we use $PPID, not session_id).
cat >/dev/null

CLAUDE_PID="$PPID"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MARKER="${PROJECT_DIR}/.claude/.session-role-by-claude-pid/${CLAUDE_PID}"

if [ ! -r "$MARKER" ]; then
  echo "AskUserQuestion blocked: cannot determine session role from ${MARKER}. If you are M, write 'manager' to that file (or call 'wow_claim_role manager' from scripts/whats-my-role.sh) and retry. If not M, route the question to M via bus (emit 'question' or 'skill-question' to manager-*)." >&2
  exit 2
fi

ROLE=$(tr -d '[:space:]' < "$MARKER")

case "$ROLE" in
  manager)
    exit 0
    ;;
  pair-programmer|senior-developer|tester|slacker)
    echo "AskUserQuestion blocked: peers route human-facing questions through M via bus. Emit 'question' (or 'skill-question' per Story 046) to manager-* with the question payload. M will relay via AskUserQuestion and reply with the human's answer." >&2
    exit 2
    ;;
  *)
    echo "AskUserQuestion blocked: marker file at ${MARKER} contains unrecognized role '${ROLE}' (expected: manager / pair-programmer / senior-developer / tester / slacker). Marker may be corrupted or stale — investigate." >&2
    exit 2
    ;;
esac
