#!/usr/bin/env bash
# Bug 0002, Layer A — per-wrapper self-throttle test.
# Sourcing spawn-rate-limit.sh + calling wow_spawn_check 6 times in
# the same window must bail on the 6th with exit 2 (caller exits) +
# EXIT_SPAWN_RATE on stderr.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}
assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name (haystack missing '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT/scripts/wow-process/spawn-rate-limit.sh"

# Case 1: lib exists + sources cleanly
[ -f "$LIB" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case1: spawn-rate-limit.sh missing at $LIB"); }

# Case 2: 5 rapid spawns allowed; 6th bails
RESULT=$(bash -c "
  . \"$LIB\"
  for i in 1 2 3 4 5 6; do
    if ! wow_spawn_check 'test-purpose'; then
      echo \"BAILED-AT-\$i\"
      exit 2
    fi
  done
  echo 'ALL-PASSED'
" 2>&1)
RC=$?
assert_eq "case2: exit 2 on overshoot" "2" "$RC"
assert_contains "case2: BAILED at iteration 6" "BAILED-AT-6" "$RESULT"
assert_contains "case2: EXIT_SPAWN_RATE on stderr" "EXIT_SPAWN_RATE" "$RESULT"
assert_contains "case2: purpose tag in message" "test-purpose" "$RESULT"

# Case 3: rolling window clears after sleep > window
RESULT=$(bash -c "
  . \"$LIB\"
  for i in 1 2 3 4 5; do wow_spawn_check 'test-window' >/dev/null 2>&1 || true; done
  sleep 3  # > WOW_RUNTIME_SPAWN_WINDOW_S default of 2s
  if wow_spawn_check 'test-window'; then echo 'OK-AFTER-WINDOW'; else echo 'STILL-BLOCKED'; fi
" 2>&1)
assert_contains "case3: window clears after timeout" "OK-AFTER-WINDOW" "$RESULT"

# Case 4: env-tunable WOW_RUNTIME_SPAWN_MAX = 2 bails on 3rd
RESULT=$(WOW_RUNTIME_SPAWN_MAX=2 bash -c "
  . \"$LIB\"
  for i in 1 2 3; do
    if ! wow_spawn_check 'tuned'; then
      echo \"BAILED-AT-\$i\"
      exit 2
    fi
  done
" 2>&1)
RC=$?
assert_eq "case4: tunable max=2 bails on 3rd" "2" "$RC"
assert_contains "case4: BAILED at iteration 3" "BAILED-AT-3" "$RESULT"

# Case 5: manager-monitor.sh sources spawn-rate-limit + uses wow_spawn_check
IDLE="$ROOT/scripts/wow-process/manager-monitor.sh"
if grep -q "spawn-rate-limit.sh" "$IDLE" && grep -q "wow_spawn_check" "$IDLE"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case5: manager-monitor.sh missing spawn-rate-limit integration")
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
