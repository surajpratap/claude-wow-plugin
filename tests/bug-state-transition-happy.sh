#!/usr/bin/env bash
# Story 159 — legal filed → triaged → fixing → fixed → verified → closed
# chain succeeds; markers + state log updated correctly.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUG_EMIT="$ROOT/scripts/bug-emit.sh"
BUG_TRANS="$ROOT/scripts/bug-state-transition.sh"
SHAPE_CHECK="$ROOT/scripts/bug-shape-check.sh"

TMPDIR_FX=$(mktemp -d)
mkdir -p "$TMPDIR_FX/implementations"

NEW=$(WOW_ROOT="$TMPDIR_FX" bash "$BUG_EMIT" \
  --reporter "t" --severity high --priority P1 \
  --affected-story 1 --affected-version 0.0.0 --title "x")

for step in "triaged|--agent-id pp-x" "fixing|--agent-id sd-x" "fixed|--agent-id sd-x --pr-url https://example/p/1 --fixed-in 0.0.1" "verified|--agent-id t-x" "closed|--agent-id m-x"; do
  status="${step%%|*}"
  args="${step#*|}"
  # shellcheck disable=SC2086
  WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 "$status" $args >/dev/null 2>&1
  if [ $? -eq 0 ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("transition to $status should succeed"); fi
  WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
  if [ $? -eq 0 ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("shape-check after transition to $status should pass"); fi
done

if grep -q "## State log" "$NEW"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("State log section should be created"); fi
LOG_LINES=$(grep -c "moved status from" "$NEW")
if [ "$LOG_LINES" -eq 5 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("state log should have 5 transition lines (got $LOG_LINES)"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
