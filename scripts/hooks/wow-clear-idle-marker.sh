#!/usr/bin/env bash
# scripts/hooks/wow-clear-idle-marker.sh — UserPromptSubmit hook.
#
# A user prompt deterministically means the WOW team now has work, so this
# hook mechanically clears the .nothing_to_do idle marker — the mechanical
# equivalent of the resume_work MCP tool (server.py handle_resume_work).
# Idempotent: a no-op when the marker is absent. Role-agnostic: clears on
# every prompt regardless of which role's session received it.
#
# Deliberately does NOT read or write AFK state (afk_active / afk_mode /
# the .afk/ audit mirror). Idle (team-has-no-work) and AFK (human-away,
# M-judged) are orthogonal: a prompt clears idle but never flips AFK.
#
# Fire-and-forget — exits 0 unconditionally on every path.

set -u

# Drain stdin first to avoid SIGPIPE on the writer; we don't parse it.
cat >/dev/null 2>&1 || true

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MARKER="${PROJECT_DIR}/implementations/.nothing_to_do"

rm -f "$MARKER" 2>/dev/null || true
exit 0
