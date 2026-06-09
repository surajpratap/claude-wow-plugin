#!/usr/bin/env bash
# Story 076 — role-process-map.json coherence guard.
#
# Verifies: (1) every value is a JSON array, (2) bus-tail is in every
# role's purpose list, (3) manager-monitor is in manager's list and the legacy
# manager-monitor entry is not (regression guard).

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAP="$ROOT/scripts/wow-process/role-process-map.json"

if [ ! -f "$MAP" ]; then
  echo "role-process-map-coherence: FAIL — map file not found at $MAP"
  exit 1
fi

# Case 1: JSON parses.
if ! jq -e '.' "$MAP" >/dev/null 2>&1; then
  echo "role-process-map-coherence: FAIL — $MAP is not valid JSON"
  exit 1
fi
PASS=$((PASS+1))

# Case 2: every value is an array.
ALL_ARRAYS=$(jq -r 'to_entries | all(.value | type == "array")' "$MAP")
assert_eq "case-2-all-values-arrays" "true" "$ALL_ARRAYS"

# Case 3: manager-monitor IS in manager's purpose list.
HAS_IDLE=$(jq -r '.manager | (index("manager-monitor") != null)' "$MAP")
assert_eq "case-3-manager-monitor-in-manager" "true" "$HAS_IDLE"

# Case 4: the renamed-away name `idle-monitor` is NOT in manager's purpose list
# (regression guard — Story 186 renamed idle-monitor back to manager-monitor).
HAS_LEGACY=$(jq -r '.manager | (index("idle-monitor") != null)' "$MAP")
assert_eq "case-4-no-legacy-idle-monitor" "false" "$HAS_LEGACY"

# Case 5: bus-tail is in every role's purpose list (bus-tail is universal).
for role in manager pair-programmer senior-developer tester slacker; do
  HAS_BUS_TAIL=$(jq -r --arg r "$role" '.[$r] | (index("bus-tail") != null)' "$MAP")
  assert_eq "case-5-bus-tail-in-$role" "true" "$HAS_BUS_TAIL"
done

# Case 6: manager's list contains exactly bus-tail + github-bridge + manager-monitor
# (no surprise entries). Length check.
MANAGER_LEN=$(jq -r '.manager | length' "$MAP")
assert_eq "case-6-manager-purpose-count" "3" "$MANAGER_LEN"

echo "role-process-map-coherence: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
