#!/usr/bin/env bash
# Story 121 — idempotent agent-id resolution. Closes the ID-drift class
# (2026-05-03 SD self-report: two senior-developer IDs emitting on the bus
# from one session) by giving role-startup procedures a way to detect an
# existing tracker for the current claude session PID + role.
#
# Usage:
#   bash wow-existing-agent-id.sh <role>
#
# Algorithm:
#   1. Resolve the canonical claude session PID via whats-my-role.sh's
#      wow_find_claude_pid PPID-walk.
#   2. Scan ${ROOT}/implementations/.agents/<role>-*.json. For each tracker,
#      read claude_pid; if it matches the session PID, treat as a candidate.
#   3. Prefer the candidate with the highest `last_line` value (most-recent
#      activity) — covers the stale-tracker-plus-fresh-tracker case from the
#      original 2026-05-03 drift.
#   4. Echo the winning agent_id (filename minus `.json`). Empty stdout if no
#      candidate.
#
# Exit 0 always — the LLM caller branches on stdout content.

set -u

ROLE="${1:-}"
if [ -z "$ROLE" ]; then
  echo "usage: wow-existing-agent-id.sh <role>" >&2
  exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
WMR="$HELPER_DIR/whats-my-role.sh"
if [ ! -f "$WMR" ]; then
  exit 0
fi

# shellcheck disable=SC1090 # dynamic resolution via wow-locate
. "$WMR"
SESSION_PID=$(wow_find_claude_pid 2>/dev/null || echo "")
if [ -z "$SESSION_PID" ]; then
  exit 0
fi

AGENTS_DIR="${WOW_AGENTS_DIR:-${ROOT}/implementations/.agents}"
if [ ! -d "$AGENTS_DIR" ]; then
  exit 0
fi

BEST_ID=""
BEST_LAST_LINE=-1
for f in "$AGENTS_DIR/${ROLE}-"*.json; do
  [ -f "$f" ] || continue
  PID_IN_FILE=$(grep -oE '"claude_pid"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null \
                | grep -oE '[0-9]+$' | head -1)
  if [ "$PID_IN_FILE" != "$SESSION_PID" ]; then
    continue
  fi
  LL=$(grep -oE '"last_line"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null \
       | grep -oE '[0-9]+$' | head -1)
  LL=${LL:-0}
  if [ "$LL" -gt "$BEST_LAST_LINE" ]; then
    BEST_LAST_LINE="$LL"
    BEST_ID=$(basename "$f" .json)
  fi
done

[ -n "$BEST_ID" ] && echo "$BEST_ID"
exit 0
