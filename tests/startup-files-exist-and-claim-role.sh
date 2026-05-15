#!/usr/bin/env bash
# plugin/tests/startup-files-exist-and-claim-role.sh
# Every _<role>-startup.md MUST exist and contain a wow_claim_role <role> invocation.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

for role in manager senior-developer pair-programmer tester slacker; do
  STARTUP="$PLUGIN_ROOT/commands/_${role}-startup.md"
  if [ ! -f "$STARTUP" ]; then
    fail "startup-file-missing: $STARTUP"
    continue
  fi
  if grep -qE "wow_claim_role[[:space:]]+${role}\b" "$STARTUP"; then
    pass
  else
    fail "claim-role-missing: $STARTUP"
  fi
done

echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
