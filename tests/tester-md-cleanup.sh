#!/usr/bin/env bash
# Story 154 — tester.md "Stop both Monitor tasks" → "Stop the bus Monitor task" cleanup.
#
# T historically had two Monitor tasks (bus-tail + a now-removed second one);
# the role-process-map at v3.20.0 only lists `bus-tail` for tester. The
# clean-exit step "Stop both Monitor tasks with TaskStop" was stale doctrine
# from the prior arrangement. This test pins the singular form and acts
# as a regression guard.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTER_MD="$ROOT/commands/tester.md"

if [ ! -f "$TESTER_MD" ]; then
  echo "tester-md-cleanup: tester.md not found at $TESTER_MD"
  exit 1
fi

# Regression: must NOT contain the plural form anymore.
if grep -qE "Stop both Monitor tasks" "$TESTER_MD"; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("tester.md still contains 'Stop both Monitor tasks' (stale doctrine)")
else
  PASS=$((PASS+1))
fi

# Pin the singular form is present.
if grep -qE "Stop the bus Monitor task" "$TESTER_MD"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("tester.md missing 'Stop the bus Monitor task' (singular form)")
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
