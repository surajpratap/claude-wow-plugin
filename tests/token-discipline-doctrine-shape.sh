#!/usr/bin/env bash
# Story 069 — shape-test the token-discipline doctrine file at
# commands/_token-discipline.md. The doctrine is M-only writes; this test
# guards against drift in the 8 required sections + size cap. Per
# amendment-2 (WOW-genericity, backlog 095): section 5 is a POINTER to
# project-side learnings, NOT a per-role catalogue. Doctrine MUST NOT
# carry concrete M/SD/PP/T/S example subsections — those live at
# implementations/learnings/<role>.md.

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

assert_no_match() {
  local name="$1"; local file="$2"; local pattern="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (unexpected match for /$pattern/ in $file)")
  else
    PASS=$((PASS+1))
  fi
}

assert_in_range() {
  local name="$1"; local actual="$2"; local lo="$3"; local hi="$4"
  if [ "$actual" -ge "$lo" ] && [ "$actual" -le "$hi" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (got $actual, expected $lo..$hi)")
  fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTRINE="$REPO_ROOT/commands/_token-discipline.md"

# Case 1: Doctrine file exists.
if [ -f "$DOCTRINE" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case-1-doctrine-exists ($DOCTRINE not found)")
  echo "token-discipline-doctrine-shape: $PASS passed, $FAIL failed"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi

# Case 2: 8 required section headers present. Per amendment-2 (backlog 095
# WOW-genericity), section 5 is a POINTER to project-side role catalogues,
# not a per-role catalogue itself.
assert_match "case-2-section-why-conserve"          "$DOCTRINE" '^## Why we conserve'
assert_match "case-2-section-delegation-rule"       "$DOCTRINE" '^## The delegation rule'
assert_match "case-2-section-well-defined"          "$DOCTRINE" '^## What.s "well-defined"'
assert_match "case-2-section-not-delegatable"       "$DOCTRINE" '^## What.s NOT delegatable'
assert_match "case-2-section-project-side-pointer"  "$DOCTRINE" '^## Project-side role catalogues'
assert_match "case-2-section-invocation-pattern"    "$DOCTRINE" '^## Subagent invocation pattern'
assert_match "case-2-section-recursive-rule"        "$DOCTRINE" '^## Recursive rule'
assert_match "case-2-section-anti-patterns"         "$DOCTRINE" '^## Anti-patterns'

# Case 3: Per amendment-2, doctrine MUST NOT contain per-role example
# subsections — those live at implementations/learnings/<role>.md. All five
# role headers must be ABSENT (M, SD, PP, T, S). Section 5 must cite the
# project-side learnings path.
assert_no_match "case-3-no-manager-subsection"          "$DOCTRINE" '^### Manager'
assert_no_match "case-3-no-senior-developer-subsection" "$DOCTRINE" '^### Senior Developer'
assert_no_match "case-3-no-pair-programmer-subsection"  "$DOCTRINE" '^### Pair Programmer'
assert_no_match "case-3-no-tester-subsection"           "$DOCTRINE" '^### Tester'
assert_no_match "case-3-no-slacker-subsection"          "$DOCTRINE" '^### Slacker'
assert_match    "case-3-cites-learnings-path"           "$DOCTRINE" 'implementations/learnings/<role>\.md'

# Case 4: File length 50 ≤ N ≤ 400 lines.
LINES=$(wc -l < "$DOCTRINE" | tr -d ' ')
assert_in_range "case-4-doctrine-length" "$LINES" 50 400

# Case 5: Canonical invocation pattern keywords present.
assert_match "case-5-mentions-Agent-tool"         "$DOCTRINE" '\bAgent\b'
assert_match "case-5-mentions-subagent_type"      "$DOCTRINE" 'subagent_type'
assert_match "case-5-mentions-model-haiku"        "$DOCTRINE" 'model:[[:space:]]*"?haiku"?|model.*haiku'
assert_match "case-5-mentions-model-sonnet"       "$DOCTRINE" 'model:[[:space:]]*"?sonnet"?|model.*sonnet'

# Case 6 (amendment-4): doctrine ALLOWS `model: opus` for subagents (rare,
# for harder bounded work where Sonnet underperforms). The previous
# "Never model: opus" rule has been dropped — this assertion guards against
# regression to the over-restrictive framing.
assert_no_match "case-6-does-not-forbid-opus-subagent" "$DOCTRINE" '[Nn]ever .*model:[[:space:]]*"?opus"?|defeats the .*cost savings'
# But the doctrine should still mention `model: opus` (now in the allowed set).
assert_match    "case-6-mentions-model-opus"           "$DOCTRINE" 'model:[[:space:]]*"?opus"?|model.*opus'

echo "token-discipline-doctrine-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
