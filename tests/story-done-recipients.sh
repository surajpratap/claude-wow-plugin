#!/usr/bin/env bash
# Asserts SD's role file describes story-done emit with pair-programmer-* in
# the recipient list (alongside tester-* and manager-*).

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_contains() { local n="$1"; local hay="$2"; local needle="$3"
  case "$hay" in *"$needle"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected match for '$needle')") ;; esac; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SD="$REPO_ROOT/commands/senior-developer.md"

LINES=$(grep -nE 'story-done.*(to:|to .*pair-programmer-\*|tester-\*|manager-\*)' "$SD" || true)

assert_contains "sd-story-done-routes-to-pp" "$LINES" "pair-programmer-*"
assert_contains "sd-story-done-still-routes-to-t" "$LINES" "tester-*"
assert_contains "sd-story-done-still-routes-to-m" "$LINES" "manager-*"

echo
echo "story-done-recipients: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
