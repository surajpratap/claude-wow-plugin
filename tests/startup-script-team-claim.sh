#!/usr/bin/env bash
# Story 152 — M-only team-claim flow shape check.
# When .my-team is absent, phase_env emits an info line indicating
# the team-claim ask-human would fire (full ask-human dispatch is
# deferred to the manager.md doctrine the new short _manager-startup.md
# references). When .my-team exists, the team is read silently.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

# Case 1: M with .my-team present → emits "env: team=<value>"
PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations"
echo "falcon" > "$PROJ/implementations/.my-team"
OUT=$(WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --role manager 2>/dev/null)
if printf '%s' "$OUT" | grep -q "env: team=falcon"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case1: M did not emit env: team=falcon")
fi
rm -rf "$PROJ"

# Case 2: M with .my-team absent → emits team-claim ask-human placeholder
PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations"
OUT=$(WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --role manager 2>/dev/null)
if printf '%s' "$OUT" | grep -q "team-claim ask-human"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case2: M without .my-team did not emit team-claim placeholder")
fi
rm -rf "$PROJ"

# Case 3: SD (non-M) with .my-team absent → emits "M will populate"
PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations"
OUT=$(WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --role senior-developer 2>/dev/null)
if printf '%s' "$OUT" | grep -q "M will populate"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case3: SD with no .my-team did not defer to M")
fi
rm -rf "$PROJ"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
