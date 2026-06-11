#!/usr/bin/env bash
# Shape-guard for commands/_ahod-doctrine.md — the single source of truth for
# AHOD mode. Required sections, size bounds, load-bearing phrases, and no
# per-role ### subsections (role notes are bullets; role detail lives in the
# role files / learnings).

set -u
PASS=0; FAIL=0; FAILED=()

assert_match() {
  local name="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); FAILED+=("$name (no match for /$pattern/)"); fi
}
assert_no_match() {
  local name="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    FAIL=$((FAIL+1)); FAILED+=("$name (unexpected match for /$pattern/)"); else PASS=$((PASS+1)); fi
}
assert_in_range() {
  local name="$1" actual="$2" lo="$3" hi="$4"
  if [ "$actual" -ge "$lo" ] && [ "$actual" -le "$hi" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); FAILED+=("$name (got $actual, expected $lo..$hi)"); fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTRINE="$REPO_ROOT/commands/_ahod-doctrine.md"

if [ ! -f "$DOCTRINE" ]; then
  echo "ahod-doctrine-shape: FAIL — $DOCTRINE not found"
  exit 1
fi

assert_match "sec-activation"    "$DOCTRINE" '^## Activation & state'
assert_match "sec-kickoff"       "$DOCTRINE" '^## Kickoff'
assert_match "sec-lifecycle"     "$DOCTRINE" '^## Owner lifecycle'
assert_match "sec-premise"       "$DOCTRINE" '^## Premise verification'
assert_match "sec-questions"     "$DOCTRINE" '^## Question routing'
assert_match "sec-refusal"       "$DOCTRINE" '^## Refusal & override'
assert_match "sec-role-notes"    "$DOCTRINE" '^## Role notes'
assert_match "sec-suspended"     "$DOCTRINE" '^## Suspended in AHOD'
assert_match "sec-in-force"      "$DOCTRINE" '^## Stays in force'
assert_match "sec-dual-duty"     "$DOCTRINE" "^## M's dual duty"
assert_match "sec-stand-down"    "$DOCTRINE" '^## Stand-down'

assert_match "cites-config"      "$DOCTRINE" 'implementations/config\.json'
assert_match "cites-helper"      "$DOCTRINE" 'wow-config\.sh'
assert_match "exact-id-dispatch" "$DOCTRINE" '[Ee]xact agent ID'
assert_match "ahod-true-flag"    "$DOCTRINE" 'ahod: true'
assert_match "review-before-pr"  "$DOCTRINE" 'code-review.*BEFORE opening the PR'
assert_match "never-ask-human"   "$DOCTRINE" 'NEVER ask the human directly'

assert_no_match "no-role-subsections" "$DOCTRINE" '^### (Manager|Senior Developer|Pair Programmer|Tester|Slacker)'

LINES=$(wc -l < "$DOCTRINE" | tr -d ' ')
assert_in_range "doctrine-length" "$LINES" 80 400

echo "ahod-doctrine-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
