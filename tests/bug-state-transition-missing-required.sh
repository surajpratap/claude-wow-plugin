#!/usr/bin/env bash
# Story 159 — transition to fixed without --pr-url/--fixed-in is refused;
# transition to duplicate without --duplicate-of is refused.

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

# Advance to fixing
WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 triaged --agent-id "pp" >/dev/null
WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 fixing --agent-id "sd" >/dev/null

# fixed without --pr-url
WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 fixed --agent-id "sd" --fixed-in 0.0.1 2>/dev/null
if [ $? -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("fixed without --pr-url should be refused"); fi

# fixed without --fixed-in
WOW_ROOT="$TMPDIR_FX" bash "$BUG_TRANS" 0001 fixed --agent-id "sd" --pr-url https://example/p/1 2>/dev/null
if [ $? -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("fixed without --fixed-in should be refused"); fi

# duplicate without --duplicate-of (from filed)
TMPDIR_FX2=$(mktemp -d)
mkdir -p "$TMPDIR_FX2/implementations"
WOW_ROOT="$TMPDIR_FX2" bash "$BUG_EMIT" \
  --reporter "t" --severity high --priority P1 \
  --affected-story 1 --affected-version 0.0.0 --title "y" >/dev/null
WOW_ROOT="$TMPDIR_FX2" bash "$BUG_TRANS" 0001 duplicate --agent-id "m" 2>/dev/null
if [ $? -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("duplicate without --duplicate-of should be refused"); fi

rm -rf "$TMPDIR_FX" "$TMPDIR_FX2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
