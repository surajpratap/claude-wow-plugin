#!/usr/bin/env bash
# Story 159 — bug-emit.sh produces a file that passes shape-check.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUG_EMIT="$ROOT/scripts/bug-emit.sh"
SHAPE_CHECK="$ROOT/scripts/bug-shape-check.sh"

TMPDIR_FX=$(mktemp -d)
mkdir -p "$TMPDIR_FX/implementations"

NEW_BUG=$(WOW_ROOT="$TMPDIR_FX" bash "$BUG_EMIT" \
  --reporter "tester-test" --severity high --priority P1 \
  --affected-story 159 --affected-version 0.0.0 --title "Test bug")
RC=$?

if [ $RC -eq 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("bug-emit should exit 0; got rc=$RC"); fi

if [ -f "$NEW_BUG" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("bug-emit should create file (got '$NEW_BUG')"); fi

WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
if [ $? -eq 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("emitted bug should pass shape-check"); fi

# Verify ID allocation (0001 for first bug)
case "$NEW_BUG" in
  *0001-test-bug.md) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); FAILED_CASES+=("first bug should get id 0001 (got '$NEW_BUG')") ;;
esac

# Emit a second bug → 0002
NEW_BUG2=$(WOW_ROOT="$TMPDIR_FX" bash "$BUG_EMIT" \
  --reporter "tester-test" --severity low --priority P3 \
  --affected-story 999 --affected-version 0.0.0 --title "Second bug")
case "$NEW_BUG2" in
  *0002-second-bug.md) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); FAILED_CASES+=("second bug should get id 0002 (got '$NEW_BUG2')") ;;
esac

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
