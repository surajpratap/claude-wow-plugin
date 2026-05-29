#!/usr/bin/env bash
# Bug 0003 FINDING-41 (MAJOR) regression guard.
# v3.29.0's phase_peer installed `trap "rm -f $tracker" EXIT INT TERM`
# which fired at startup.sh exit — defeating the dead-agent-ID guard
# fix story 152 was meant to deliver (peers' pongs to the preflight
# ID arrive after startup exits, find no tracker, get rejected).
#
# Story 161 removes the trap. Lifecycle splits: phase_peer writes,
# M's operating doctrine destroys after pong-collection. This test:
#   (a) sources phase_peer + runs it; asserts tracker file persists
#       after the function returns (no trap residue)
#   (b) regression guards: phase_peer.sh has no `trap.*tracker_path`;
#       manager.md has the cleanup doctrine paragraph.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHASE_PEER="$ROOT/scripts/startup/phase_peer.sh"
LIB_EMIT="$ROOT/scripts/startup/lib_emit.sh"
MANAGER_MD="$ROOT/commands/manager.md"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations/.agents"

# Case 1: source + invoke phase_peer; tracker must persist post-call.
(
  set +u
  export WOW_ROOT="$PROJ"
  # shellcheck disable=SC1090
  . "$LIB_EMIT"
  # shellcheck disable=SC1090
  . "$PHASE_PEER"
  phase_peer manager >/dev/null 2>&1
)
RC=$?
assert_eq "case1: phase_peer returns 0" "0" "$RC"

tracker_count=$(ls "$PROJ/implementations/.agents/manager-preflight-"*.json 2>/dev/null | wc -l | tr -d ' ')
assert_eq "case1: preflight tracker persists post-exit (was removed by trap pre-fix)" "1" "$tracker_count"

# Case 2: regression guard — phase_peer.sh has no trap on tracker_path
if grep -E 'trap[[:space:]]+.*tracker_path' "$PHASE_PEER" >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("case2: phase_peer.sh still installs trap on tracker_path (FINDING-41 regression)")
else
  PASS=$((PASS+1))
fi

# Case 3: regression guard — manager.md has the cleanup doctrine paragraph
if grep -q "manager-preflight" "$MANAGER_MD"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case3: manager.md missing manager-preflight cleanup doctrine (FINDING-41 handoff broken)")
fi

if grep -q "Post-startup preflight cleanup" "$MANAGER_MD"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case3: manager.md missing 'Post-startup preflight cleanup' section header")
fi

rm -rf "$PROJ"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
