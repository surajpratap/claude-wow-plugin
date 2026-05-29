#!/usr/bin/env bash
# Story 158 — slash command doctrine spells out the learnings-consolidated
# emit + the always-emit invariant. Doctrine-grep test.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_grep() {
  local name="$1"; local pattern="$2"; local file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (pattern '$pattern' missing from $file)"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
META="$ROOT/commands/_meta/consolidate-memory.md"
RETRO="$ROOT/commands/_retro-doctrine.md"

assert_grep "slash command emits learnings-consolidated" "learnings-consolidated" "$META"
assert_grep "slash command notes always-emit invariant"  "[Aa]lways emit"          "$META"
assert_grep "retro doctrine adds the consolidate-memory nudge" "repair.*consolidate-memory" "$RETRO"
assert_grep "retro doctrine aggregates learnings-consolidated payload counts" "learnings-consolidated" "$RETRO"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
