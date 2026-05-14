#!/usr/bin/env bash
# Asserts PP's role file documents handlers for all six event-driven
# review checkpoints.

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_grep() { local n="$1"; local pat="$2"; local file="$3"
  if grep -qE "$pat" "$file"; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (no match for '$pat')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PP="$REPO_ROOT/commands/pair-programmer.md"

assert_grep "pp-handles-plan-ready-for-review" 'plan-ready-for-review' "$PP"
assert_grep "pp-handles-plan-done" 'plan-done' "$PP"
assert_grep "pp-handles-story-done" 'story-done' "$PP"
assert_grep "pp-handles-bug-verified" 'bug-verified' "$PP"
assert_grep "pp-handles-pr-review-nudge" 'pr-review|pr-comment' "$PP"

echo
echo "pp-event-driven-reviews: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
