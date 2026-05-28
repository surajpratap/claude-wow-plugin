#!/usr/bin/env bash
# Asserts the placeholder-leak-guard workflow fires on push-to-main, NOT on
# pull_request. Trigger drift caused PRs of sprint 2026-05-28-dx-batch to
# false-fail on the sprint-mode NEXT-<id>.md entry files (legitimate pre-merge
# state). Backlog 194.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/placeholder-leak-guard.yml"

fail=0

assert_contains() {
  local needle="$1"
  local label="$2"
  if grep -q -F "$needle" "$WORKFLOW"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label — expected '$needle' in $WORKFLOW" >&2
    fail=1
  fi
}

assert_not_contains() {
  local needle="$1"
  local label="$2"
  if ! grep -q -F "$needle" "$WORKFLOW"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label — '$needle' should NOT appear in $WORKFLOW" >&2
    fail=1
  fi
}

assert_contains "push:" "trigger is push"
assert_contains "branches: [main]" "branches set to main"
assert_not_contains "pull_request:" "trigger is NOT pull_request"

if [ "$fail" -ne 0 ]; then
  echo
  echo "placeholder-leak-guard.yml trigger drift detected." >&2
  exit 1
fi
