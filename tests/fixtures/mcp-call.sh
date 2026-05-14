#!/usr/bin/env bash
# mcp-call.sh — test helper that spawns the claude-wow MCP server, sends
# a single JSON-RPC tools/call request via stdin, and prints the response
# JSON to stdout. Story 062.
#
# Usage:
#   bash tests/fixtures/mcp-call.sh <tool-name> '<args-json>'
#
# Examples:
#   bash tests/fixtures/mcp-call.sh bus_emit '{"from":"senior-developer-...","type":"ping","to":"*"}'
#
# Reads $CLAUDE_PROJECT_DIR (defaults to repo root via git rev-parse).
# Caller controls the bus file via that env var (use a tmp dir to isolate).

set -u

TOOL="${1:?usage: <tool-name> '<args-json>'}"
ARGS_JSON="${2:?usage: <tool-name> '<args-json>'}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVER="$REPO_ROOT/mcp/claude-wow-server/server.py"

if [ ! -f "$SERVER" ]; then
  echo "mcp-call: server not found at $SERVER" >&2
  exit 1
fi

REQ=$(jq -cn --arg tool "$TOOL" --argjson args "$ARGS_JSON" \
  '{jsonrpc:"2.0", id:1, method:"tools/call", params:{name:$tool, arguments:$args}}')

# Pipe the single request; the server reads stdin until EOF.
echo "$REQ" | python3 "$SERVER" 2>/dev/null
