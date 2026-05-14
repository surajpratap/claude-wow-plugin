#!/usr/bin/env bash
# Story 054 — fswatch baseline regression: assert /implementations/.github/
# is in PP and T role-file MUST-include enumeration AND example shape.
#
# Closes the v2.6.0 baseline-propagation gap (protocol baseline gained
# /implementations/.github/ but PP/T MUST-include + example shape lagged,
# so agents copying from the visible role-file template silently dropped it).
#
# Cases:
# 1. PP MUST-include lists /implementations/\.github/
# 2. PP example shape includes -e '/implementations/\.github/'
# 3. T MUST-include lists /implementations/\.github/
# 4. T example shape includes -e '/implementations/\.github/'
# 5. _agent-protocol.md universal baseline still lists /implementations/\.github/
# 6. M role file has no fswatch arm (sanity — M uses GitHub bridge instead)
# 7. SD role file has no fswatch arm (sanity — SD reads bus only)
# 8. S role file has no generic fswatch arm (sanity — S tails Slack feed + bus)

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

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PP="$ROOT/commands/pair-programmer.md"
T="$ROOT/commands/tester.md"
M="$ROOT/commands/manager.md"
SD="$ROOT/commands/senior-developer.md"
S="$ROOT/commands/slacker.md"

# -----------------------------------------------------------------------------
# Case 1 (Story 071): the fswatch-peer wrapper carries the github-bridge
# exclude in its FSWATCH_EXCLUDES defaults. PP's role file no longer carries
# inline -e patterns (mechanical-over-prose refactor); the baseline lives
# in the wrapper script.
# -----------------------------------------------------------------------------
FSWATCH_WRAPPER="$ROOT/scripts/wow-process/fswatch-peer.sh"
if [ -f "$FSWATCH_WRAPPER" ] && grep -qE 'implementations/\\?\.github/' "$FSWATCH_WRAPPER"; then
  R1="present"
else
  R1="missing"
fi
assert_eq "case-1-fswatch-wrapper-has-github" "present" "$R1"

# -----------------------------------------------------------------------------
# Case 2 (Story 071): PP's role file points at the fswatch-peer wrapper.
# -----------------------------------------------------------------------------
if grep -q 'scripts/wow-process/fswatch-peer\.sh' "$PP"; then
  R2="present"
else
  R2="missing"
fi
assert_eq "case-2-pp-references-fswatch-wrapper" "present" "$R2"

# -----------------------------------------------------------------------------
# Case 3: T no longer arms fswatch (Story 069 removed T's fswatch monitor).
# Assert tester.md has zero `fswatch` references — the baseline is N/A for T.
# -----------------------------------------------------------------------------
if grep -q 'fswatch' "$T"; then
  R3="present"
else
  R3="absent"
fi
assert_eq "case-3-t-fswatch-removed" "absent" "$R3"

# -----------------------------------------------------------------------------
# Case 4: T no longer has the fswatch example shape (Story 069 removal).
# -----------------------------------------------------------------------------
if grep -qF "-e '/implementations/\\.github/'" "$T"; then
  R4="present"
else
  R4="absent"
fi
assert_eq "case-4-t-fswatch-example-removed" "absent" "$R4"

# -----------------------------------------------------------------------------
# Case 5: _agent-protocol.md universal baseline still lists /implementations/\.github/
# Resolve protocol path the same way agents do.
# -----------------------------------------------------------------------------
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENT_PROTOCOL=$(
  ls "$ROOT/commands/_agent-protocol.md" 2>/dev/null \
  || ls "$ROOT/.claude/commands/_agent-protocol.md" 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/commands/_agent-protocol.md 2>/dev/null | head -1
)
if [ -n "$AGENT_PROTOCOL" ] && [ -f "$AGENT_PROTOCOL" ]; then
  if grep -q 'implementations/\\\.github/' "$AGENT_PROTOCOL"; then
    R5="present"
  else
    R5="missing"
  fi
else
  R5="protocol-file-not-found"
fi
assert_eq "case-5-agent-protocol-baseline-has-github" "present" "$R5"

# -----------------------------------------------------------------------------
# Case 6: M has no fswatch arm step (sanity — scope is PP + T only)
# Match either the role-file Monitor-arm prose pattern OR the literal
# `exec fswatch -r` invocation.
# -----------------------------------------------------------------------------
if grep -qE 'exec fswatch -r|fswatch.*Monitor.*persistent.*description.*M fswatch' "$M"; then
  R6="has-fswatch-arm"
else
  R6="no-fswatch-arm"
fi
assert_eq "case-6-m-no-fswatch-arm" "no-fswatch-arm" "$R6"

# -----------------------------------------------------------------------------
# Case 7: SD has no fswatch arm step (sanity — scope is PP + T only)
# -----------------------------------------------------------------------------
if grep -qE 'exec fswatch -r|fswatch.*Monitor.*persistent.*description.*SD fswatch' "$SD"; then
  R7="has-fswatch-arm"
else
  R7="no-fswatch-arm"
fi
assert_eq "case-7-sd-no-fswatch-arm" "no-fswatch-arm" "$R7"

# -----------------------------------------------------------------------------
# Case 8: S has no generic fswatch arm step (sanity — scope is PP + T only)
# S verifies fswatch as env dep + tails Slack feed via tail -F, but does NOT
# arm a repo-wide fswatch monitor.
# -----------------------------------------------------------------------------
if grep -qE 'exec fswatch -r|fswatch.*Monitor.*persistent.*description.*S fswatch' "$S"; then
  R8="has-fswatch-arm"
else
  R8="no-fswatch-arm"
fi
assert_eq "case-8-s-no-fswatch-arm" "no-fswatch-arm" "$R8"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "role-fswatch-baseline: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
