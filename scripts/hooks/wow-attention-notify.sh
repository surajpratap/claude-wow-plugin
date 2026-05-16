#!/usr/bin/env bash
# scripts/hooks/wow-attention-notify.sh — Notification hook.
#
# Plays the M attention sound iff: the session role is manager AND a fresh
# attention marker (implementations/.attention-requested, mtime within a
# 15-minute TTL) exists. Otherwise a silent no-op. Fire-and-forget — always
# exits 0; the marker is single-use and consumed on play (or when stale).
#
# Role detection: the hook is spawned as a direct child of Claude Code, so
# $PPID is the Claude session PID (same pattern as check-askuserquestion-role.sh).
set -u

# Hook lives at plugin/scripts/hooks/ — plugin root is two levels up. CC always
# sets CLAUDE_PLUGIN_ROOT for hooks; the ../.. fallback is belt-and-suspenders.
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

cat >/dev/null   # consume the hook stdin payload (unused)

MARKER="${PROJECT_DIR}/.claude/.session-role-by-claude-pid/${PPID}"
[ -r "$MARKER" ] || exit 0
ROLE=$(tr -d '[:space:]' < "$MARKER")
[ "$ROLE" = "manager" ] || exit 0

ATTN="${PROJECT_DIR}/implementations/.attention-requested"
[ -e "$ATTN" ] || exit 0

# Stale marker (mtime older than 15 min) — clear it, do not play. find -mmin
# is portable across BSD (macOS) and GNU find.
if [ -n "$(find "$ATTN" -mmin +15 2>/dev/null)" ]; then
  rm -f "$ATTN"
  exit 0
fi

bash "${PLUGIN_DIR}/bin/wow-attention" >/dev/null 2>&1
rm -f "$ATTN"
exit 0
