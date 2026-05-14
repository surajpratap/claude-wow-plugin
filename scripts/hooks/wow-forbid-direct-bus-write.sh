#!/usr/bin/env bash
# Story 073 — PreToolUse hook: block direct writes to the bus file.
#
# Reads tool-call JSON on stdin. Blocks Bash command strings that match
# write-context operators (`>>`, `>`, `tee`, `sed -i`) RIGHT-adjacent to the
# bus path (so `cat bus > output` is NOT blocked — that's a read of the bus
# into another file). Blocks Write/Edit/MultiEdit/NotebookEdit tool calls
# whose `file_path` is the bus.
#
# Exit codes:
#   0 — allow (no match, or jq missing/graceful fallback)
#   2 — block (matched a direct-write pattern; stderr carries the message)

set -u

CANONICAL_MSG="Direct writes to implementations/.message-bus.jsonl are blocked at the tool layer. Use the mcp__claude-wow__bus_emit tool. If MCP itself fails, follow commands/_mcp-failure-fallback.md."

STDIN_JSON=$(cat 2>/dev/null || echo "")

if ! command -v jq >/dev/null 2>&1; then
  echo "[forbid-direct-bus-write] jq not on PATH; hook permitted call (graceful fallback)" >&2
  exit 0
fi

TOOL_NAME=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$TOOL_NAME" ] || exit 0

BUS_PATH_SUFFIX='/implementations/\.message-bus\.jsonl'

case "$TOOL_NAME" in
  Bash)
    CMD=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$CMD" ] || exit 0
    if printf '%s' "$CMD" | grep -qE '(>>|>|tee|sed -i)[[:space:]].*'"$BUS_PATH_SUFFIX"; then
      echo "$CANONICAL_MSG" >&2
      exit 2
    fi
    ;;
  Write|Edit|MultiEdit|NotebookEdit)
    FILE_PATH=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [ -n "$FILE_PATH" ] || exit 0
    if printf '%s' "$FILE_PATH" | grep -qE "$BUS_PATH_SUFFIX"'$'; then
      echo "$CANONICAL_MSG" >&2
      exit 2
    fi
    ;;
esac

exit 0
