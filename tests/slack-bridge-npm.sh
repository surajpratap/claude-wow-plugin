#!/usr/bin/env bash
# Wrapper that runs the bridge/slack/ npm test suite from tests/run-all.sh.
# Bridges the bash test runner with the TypeScript / node:test suite at
# bridge/slack/tests/smoke.test.ts.
#
# Behavior:
#   - If node_modules/ is missing, runs `npm ci` (one-time install per
#     fresh worktree). If npm ci fails, exits 1 (treated as a real test
#     failure — the bridge can't be exercised offline, and silently
#     skipping would mask network/install regressions).
#   - Then runs `npm test` from bridge/slack/. Exit code propagates.

set -e

BRIDGE_DIR="$(cd "$(dirname "$0")/../bridge/slack" && pwd)"
cd "$BRIDGE_DIR"

if [ ! -d node_modules ]; then
  if ! npm ci --silent >/dev/null 2>&1; then
    printf 'slack-bridge-npm: npm ci failed; cannot run smoke test\n' >&2
    exit 1
  fi
fi

exec npm test --silent
