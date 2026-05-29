#!/usr/bin/env bash
# Story 159 — illegal transitions refused with non-zero exit.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUG_EMIT="$ROOT/scripts/bug-emit.sh"
BUG_TRANS="$ROOT/scripts/bug-state-transition.sh"

TMPDIR_FX=$(mktemp -d)
mkdir -p "$TMPDIR_FX/implementations"

WOW_ROOT="$TMPDIR_FX" bash "$BUG_EMIT" \
  --reporter "t" --severity high --priority P1 \
  --affected-story 1 --affected-version 0.0.0 --title "x" >/dev/null

# filed -> verified is illegal (must go through triaged → fixing → fixed)
WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 verified --agent-id "t" 2>/dev/null
if [ $? -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("filed→verified should be refused"); fi

# filed -> fixing is illegal
WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 fixing --agent-id "t" 2>/dev/null
if [ $? -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("filed→fixing should be refused"); fi

# Advance to triaged, then check triaged -> verified is illegal
WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 triaged --agent-id "pp" >/dev/null 2>&1
WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 verified --agent-id "t" 2>/dev/null
if [ $? -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("triaged→verified should be refused"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
