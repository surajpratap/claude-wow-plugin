#!/usr/bin/env bash
# Story 159 — every implementations/bugs/*.md file in this repo passes
# bug-shape-check post-migration. Forward-compatible — picks up any new
# bug files as they're added.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHAPE_CHECK="$PLUGIN_ROOT/scripts/bug-shape-check.sh"

# Walk up from plugin/tests/ to find the repo root.
REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"

OUT=$(WOW_ROOT="$REPO_ROOT" bash "$SHAPE_CHECK" 2>&1)
RC=$?

if [ $RC -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("bug-shape-check failed on existing bugs: $OUT")
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
