#!/usr/bin/env bash
# Story 145 — merge-authority-parse.sh is SECURITY-CRITICAL + FAIL-CLOSED: it
# detects a CANDIDATE grant only (never decides authority); anything ambiguous
# (negation / question / conditional / third-party / non-grant) must be a
# NON-candidate (exit 1), never a grant. Validated against REAL last-sprint
# phrases + a security-negative battery (the 142 real-corpus lesson, security flavor).

set -u
PASS=0; FAIL=0; FAILED=()
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
S="$ROOT/scripts/merge-authority-parse.sh"
[ -f "$S" ] || { echo "merge-authority-parse: SKIP — $S not found"; exit 0; }

RC=0; OUT=""
run(){ OUT=$(bash "$S" "$1" 2>/dev/null); RC=$?; }

# grant <phrase> <expected-scope>
grant(){
  run "$1"
  if [ "$RC" -ne 0 ]; then FAIL=$((FAIL+1)); FAILED+=("grant '$1' expected candidate, got exit $RC"); return; fi
  local sc; sc=$(printf '%s' "$OUT" | grep -oE '"scope":"[^"]*"' | sed 's/.*:"//;s/"//')
  if [ "$sc" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("grant '$1' scope '$sc' != '$2'"); fi
  # a candidate must NEVER be self-describing as active authority
  if printf '%s' "$OUT" | grep -q '"candidate":true'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("grant '$1' missing candidate:true"); fi
}
# reject <phrase>  (must be a NON-candidate — fail-closed)
reject(){
  run "$1"
  if [ "$RC" -eq 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("SECURITY: '$1' expected NON-candidate (exit 1), got exit $RC out=$OUT"); fi
}

# ---- REAL last-sprint grants ----
grant "M can merge prs in this sprint" "this-sprint"
grant "Yeah m can merge the final pr as well" "final-integration"
grant "manager can merge each pr" "per-item"
grant "you can merge to main" "final-integration"
grant "m can merge prs" "unscoped"

# ---- SECURITY negatives (must NEVER be a candidate) ----
reject "M can't merge the final pr"
reject "M cannot merge"
reject "M can not merge yet"
reject "do not let M merge"
reject "M should not merge"
reject "can M merge to main?"
reject "could manager merge the pr?"
reject "once tests pass M can merge final"
reject "if CI is green M can merge"
reject "after review M can merge"
reject "he can merge the pr"
reject "they can merge"
reject "when is standup?"
reject "integration tests pass now"
reject "final approval is done"
reject "revoke M's merge authority"
reject "M no longer can merge"

# ---- usage ----
run ""; if [ "$RC" -eq 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("empty arg should exit 2, got $RC"); fi

echo "merge-authority-parse: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
