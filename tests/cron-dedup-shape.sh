#!/usr/bin/env bash
# Story 065 — doc-shape test for orphan-cron dedup convention in
# commands/manager.md. CronList/CronDelete are Claude Code primitives
# (not bash-testable); this test asserts the prose convention is in
# place so M's prompt encodes the dedup discipline.
#
# Mirrors the precedent set by tests/plugin-hooks-shape.sh (Story 060).

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_match() {
  local name="$1"; local file="$2"; local pattern="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (no match for /$pattern/ in $file)")
  fi
}

assert_match_count_ge() {
  local name="$1"; local file="$2"; local pattern="$3"; local minimum="$4"
  local n
  n=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
  if [ "$n" -ge "$minimum" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected ≥$minimum matches for /$pattern/, got $n in $file)")
  fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MGR="$REPO_ROOT/commands/manager.md"

# -----------------------------------------------------------------------------
# Case 1: Phase 3 step 7 contains CronList + CronDelete dedup pseudo-prose.
# -----------------------------------------------------------------------------
# Look for the Phase-3 step-7 area mentioning pre-arm orphan dedup, with both
# CronList and CronDelete and the <<autonomous-loop>> literal.
assert_match "case-1-phase3-step7-cronlist" "$MGR" 'pre-arm orphan dedup.*CronList|CronList.*pre-arm orphan'
assert_match "case-1-phase3-step7-crondelete" "$MGR" 'CronDelete\(entry\.id\)|CronDelete\(<id>\)'
assert_match "case-1-phase3-step7-loop-literal" "$MGR" 'entry\.prompt == "<<autonomous-loop>>"'

# -----------------------------------------------------------------------------
# Case 2: Cron-tick handler START contains belt-and-braces dedup.
# -----------------------------------------------------------------------------
assert_match "case-2-belt-and-braces" "$MGR" 'Belt-and-braces orphan-cron dedup'
assert_match "case-2-tick-cronlist" "$MGR" 'scan via `CronList`.*<<autonomous-loop>>|`CronList`.*more than one entry has prompt `<<autonomous-loop>>`'
# The tick handler emits a status diagnostic via the MCP tool.
assert_match "case-2-tick-mcp-emit" "$MGR" 'mcp__claude-wow__bus_emit'

# -----------------------------------------------------------------------------
# Case 3: ## Orphan-cron dedup subsection exists in manager.md.
# -----------------------------------------------------------------------------
assert_match "case-3-subsection-header" "$MGR" '^## Orphan-cron dedup'
# Subsection should describe both enforcement points.
assert_match "case-3-subsection-points" "$MGR" 'Pre-arm dedup at Phase 3 step 7'
assert_match "case-3-subsection-belt" "$MGR" 'Belt-and-braces at every cron-tick'

# -----------------------------------------------------------------------------
# Case 4: Pseudo-prose patterns reference the literal <<autonomous-loop>>
# string (the cron prompt M arms). Must appear ≥3× across the dedup contexts:
# Phase 3 step 7 pre-arm + cron-tick belt-and-braces + Orphan-cron subsection.
# (Plus existing reference at the original Phase 3 CronCreate line — total ≥4.)
# -----------------------------------------------------------------------------
assert_match_count_ge "case-4-loop-literal-references" "$MGR" '<<autonomous-loop>>' 4

echo "cron-dedup-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
