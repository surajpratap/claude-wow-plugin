#!/usr/bin/env bash
# plugin/tests/startup-files-exist-and-claim-role.sh
# Every _<role>-startup.md MUST exist; either it (or its frozen
# _<role>-startup-legacy.md companion during the Story-152 transition
# release) MUST contain a wow_claim_role <role> invocation. The
# legacy companion is the source of truth for the prose-doctrine
# convention; the new short _<role>-startup.md is the invocation
# recipe. Story 152's startup.sh phase_bootstrap is what actually
# claims the role marker at runtime — this test pins the convention
# stays documented somewhere in commands/.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

for role in manager senior-developer pair-programmer tester slacker; do
  STARTUP="$PLUGIN_ROOT/commands/_${role}-startup.md"
  LEGACY="$PLUGIN_ROOT/commands/_${role}-startup-legacy.md"
  if [ ! -f "$STARTUP" ]; then
    fail "startup-file-missing: $STARTUP"
    continue
  fi
  # Check the new short file first, then the legacy companion.
  if grep -qE "wow_claim_role[[:space:]]+${role}\b" "$STARTUP"; then
    pass
  elif [ -f "$LEGACY" ] && grep -qE "wow_claim_role[[:space:]]+${role}\b" "$LEGACY"; then
    pass
  else
    fail "claim-role-missing: $STARTUP (and legacy companion absent or missing the convention)"
  fi
done

echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
