#!/usr/bin/env bash
# Story 159 FINDING-44 fix: bug-state-transition.sh auto-emits the
# corresponding bus message (`bug-fixing`/`bug-fixed`/`bug-closed`) via
# the MCP CLI on the respective transitions. The plan + senior-developer.md
# doctrine both promise this; this test guards against regression.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/bug-state-transition.sh"

# Source-grep: the script must contain the bus-emit pathway for fixing/
# fixed/closed transitions. The MCP CLI absence is silent (best-effort),
# but the code itself must be present.
if grep -q "fixing|fixed|closed" "$SCRIPT"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("script missing case-arm for bus emit transitions"); fi

if grep -q "bus-emit" "$SCRIPT"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("script missing 'bus-emit' MCP CLI call"); fi

if grep -q 'MSG_JSON=' "$SCRIPT"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("script missing MSG_JSON construction"); fi

# Verify env-var passing (no python3 -c interpolation per bug 0005 lesson).
if grep -q "python3 - <<'PY'" "$SCRIPT"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("script should use python3 heredoc, not -c interpolation"); fi

# Verify each of the three emit types is produced via the env var pattern.
for t in bug-fixing bug-fixed bug-closed; do
  if grep -q "bug-\${NEW_STATUS}" "$SCRIPT" || grep -q "TYPE_E.*$t" "$SCRIPT"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("type '$t' construction missing")
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
