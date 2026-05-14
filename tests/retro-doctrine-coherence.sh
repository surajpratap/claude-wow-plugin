#!/usr/bin/env bash
# Story 070 — coherence test for commands/_retro-doctrine.md.
# Asserts file existence + 6 canonical section headers + length bounds +
# every role file references the doctrine path on a startup-read line +
# no role file retains a Sprint-retro-etiquette / Sprint-end-learnings-refresh
# section header (negative — confirms strip).

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
DOCTRINE="$REPO_ROOT/commands/_retro-doctrine.md"

# Case 1: Doctrine file exists.
if [ -f "$DOCTRINE" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case-1-doctrine-exists ($DOCTRINE not found)")
  echo "retro-doctrine-coherence: $PASS passed, $FAIL failed"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi

# Case 2: 6 canonical section headers present (h2 level).
assert_match "case-2-section-trigger"        "$DOCTRINE" '^## Trigger condition'
assert_match "case-2-section-flow"           "$DOCTRINE" '^## Multi-party flow'
assert_match "case-2-section-etiquette"      "$DOCTRINE" '^## Etiquette'
assert_match "case-2-section-learnings"      "$DOCTRINE" '^## Learnings-refresh window'
assert_match "case-2-section-action-items"   "$DOCTRINE" '^## Action items to backlog'
assert_match "case-2-section-manifest-flip"  "$DOCTRINE" '^## Sprint manifest status flip'

# Case 3: File length 50 ≤ N ≤ 300 lines.
LINES=$(wc -l < "$DOCTRINE" | tr -d ' ')
assert_in_range "case-3-doctrine-length" "$LINES" 50 300

# Case 4: Each role file references the doctrine path on a startup-read line.
for role in manager senior-developer pair-programmer tester slacker; do
  assert_match "case-4-role-${role}-references-doctrine" "$REPO_ROOT/commands/${role}.md" 'commands/_retro-doctrine\.md'
done

# Case 5: No role file retains the stripped section headers (any header level).
for role in manager senior-developer pair-programmer tester slacker; do
  assert_no_match "case-5-role-${role}-no-etiquette-section"  "$REPO_ROOT/commands/${role}.md" '^#+\s+Sprint retro etiquette'
  assert_no_match "case-5-role-${role}-no-learnings-section"  "$REPO_ROOT/commands/${role}.md" '^#+\s+Sprint-end learnings refresh'
done

# Case 6: M's role file no longer carries the Phase 4 — Retro section header.
assert_no_match "case-6-manager-no-phase-4-retro" "$REPO_ROOT/commands/manager.md" '^#+\s+Phase 4 — Retro'

# Case 7: PP retains the Sprint review-closed signal section (protocol message
# documentation; not retro behavior — must NOT have been stripped).
assert_match "case-7-pp-retains-review-closed-signal" "$REPO_ROOT/commands/pair-programmer.md" '^#+\s+Sprint review-closed signal'

# Case 8: Schema row for read-retro-doctrine present in _agent-protocol.md.
assert_match "case-8-protocol-has-read-retro-doctrine" "$REPO_ROOT/commands/_agent-protocol.md" '\| `read-retro-doctrine` \|'

echo "retro-doctrine-coherence: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
