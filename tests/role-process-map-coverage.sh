#!/usr/bin/env bash
# Story 154 — role-process-map.json coverage with '?' conditional flag.
#
# Story 154 introduced the '?' suffix convention for conditional purposes
# (slack-bridge-spawn?, slack-events-feed?). This test pins:
#   1. The new conditional purposes appear in the slacker entry.
#   2. The '?' suffix is map-level only — downstream consumers
#      (monitor-spec.sh, post-compact-restore.sh) strip it.
#   3. monitor-spec.sh predicate matches both bare and '?'-flagged
#      entries when invoked with the canonical purpose name.
#   4. Every non-conditional purpose still has a corresponding
#      ${PURPOSE}.sh wrapper script (regression guard).
#   5. Slack purposes ('?'-flagged) are exempt from the wrapper-exists
#      check — they're slacker-internal (slacker.md owns re-arm).
#   6. post-compact-restore.sh strips '?' before computing tracker
#      fields / pidfile names.

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
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAP="$ROOT/scripts/wow-process/role-process-map.json"
RESTORE="$ROOT/scripts/wow-process/post-compact-restore.sh"
SPEC="$ROOT/scripts/wow-process/monitor-spec.sh"

# ── Case 1: slack conditional purposes are present in slacker entry.
SLACKER=$(jq -r '.slacker | join(",")' "$MAP")
assert_contains "case1: slack-bridge-spawn? in slacker entry" "slack-bridge-spawn?" "$SLACKER"
assert_contains "case1: slack-events-feed? in slacker entry" "slack-events-feed?" "$SLACKER"

# ── Case 2: monitor-spec.sh predicate uses rtrimstr to match '?'-flagged entries.
assert_contains "case2: monitor-spec.sh uses rtrimstr predicate" 'rtrimstr("?")' "$(cat "$SPEC")"

# ── Case 3: predicate accepts the canonical name (no '?') against a '?'-flagged map entry.
MATCH=$(jq -nc --arg r slacker --arg p slack-bridge-spawn \
  '{slacker: ["bus-tail", "slack-bridge-spawn?"]} | .[$r] // [] | any((. | rtrimstr("?")) == $p)')
assert_eq "case3: predicate matches stripped purpose" "true" "$MATCH"

# ── Case 4: every NON-conditional purpose has a ${PURPOSE}.sh wrapper.
NONCOND_PURPOSES=$(jq -r '[.[][]] | unique | .[] | select(endswith("?") | not)' "$MAP")
for p in $NONCOND_PURPOSES; do
  if [ -f "$ROOT/scripts/wow-process/${p}.sh" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("case4: missing wrapper for non-conditional purpose '$p'")
  fi
done

# ── Case 5: '?'-flagged purposes don't need a ${PURPOSE}.sh wrapper.
COND_PURPOSES=$(jq -r '[.[][]] | unique | .[] | select(endswith("?"))' "$MAP")
COND_COUNT=$(echo "$COND_PURPOSES" | grep -c . || true)
if [ "$COND_COUNT" -ge 2 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case5: expected ≥2 conditional purposes (got $COND_COUNT)")
fi

# ── Case 6: post-compact-restore.sh strips '?' before downstream use.
assert_contains "case6: post-compact-restore strips '?'" 'p_raw%?' "$(cat "$RESTORE")"
assert_contains "case6: post-compact-restore guards creds for slack-*" 'implementations/.slack/.bridge-pid' "$(cat "$RESTORE")"

# ── Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
