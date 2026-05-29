#!/usr/bin/env bash
# Story 158 — assert learnings-consolidated is in MCP server's
# ALLOWED_TYPES. Story 087 test pattern.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$ROOT/mcp/claude-wow-server/server.py"

if grep -qE '"learnings-consolidated"' "$SERVER" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("server.py ALLOWED_TYPES missing learnings-consolidated literal")
fi

# Also assert _agent-protocol.md documents the new type
PROTO="$ROOT/commands/_agent-protocol.md"
if grep -q "learnings-consolidated" "$PROTO" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("_agent-protocol.md missing learnings-consolidated entry")
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
