#!/usr/bin/env bash
# Story 046 — superpowers skill-question / skill-answer bus protocol test.
#
# Pure protocol-fixture test. Stubs the Skill tool entirely (asserts the
# bus messages, not skill execution). Verifies:
#  - skill-question payload shape (5 fields)
#  - skill-answer in_reply_to correlation
#  - non-matching in_reply_to is ignored
#  - M relay attribution shape
#  - timeout returns timeout marker
#  - multi-question isolation (no cross-correlation)
#  - pre-approved skill list per role (PP / SD / T)

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

# Build a skill-question emit payload (mirrors role-file bash example).
build_skill_question() {
  local from="$1" q_id="$2" skill="$3" question="$4" options_json="$5" ctx="$6"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg from "$from" --arg q_id "$q_id" --arg skill "$skill" \
    --arg question "$question" --argjson options "$options_json" --arg ctx "$ctx" \
    '{ts:$ts, from:$from, to:"manager-*", type:"skill-question", payload:{question_id:$q_id, skill:$skill, question:$question, options:$options, context_excerpt:$ctx}}'
}

# Build a skill-answer emit (M side).
build_skill_answer() {
  local from="$1" to="$2" answer="$3" in_reply_to="$4"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg from "$from" --arg to "$to" --arg answer "$answer" --arg in_reply_to "$in_reply_to" \
    '{ts:$ts, from:$from, to:$to, type:"skill-answer", payload:{answer:$answer, in_reply_to:$in_reply_to}}'
}

# Mirror peer's poll: scan bus for skill-answer matching question_id.
poll_for_answer() {
  local bus="$1" q_id="$2"
  jq -r --arg q_id "$q_id" 'select(.type == "skill-answer" and .payload.in_reply_to == $q_id) | .payload.answer' "$bus" 2>/dev/null | head -1
}

# Mirror M relay attribution computation.
m_relay_header() {
  local from_agent_id="$1" skill="$2"
  local role
  case "$from_agent_id" in
    pair-programmer-*) role="pair-programmer" ;;
    senior-developer-*) role="senior-developer" ;;
    tester-*) role="tester" ;;
    slacker-*) role="slacker" ;;
    *) role="unknown" ;;
  esac
  echo "from $role via skill $skill"
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: skill-question payload shape valid (5 fields).
PAYLOAD=$(build_skill_question "senior-developer-001" "q-abc" "superpowers:writing-plans" "Q?" '["a","b"]' "ctx")
TYPE=$(echo "$PAYLOAD" | jq -r '.type')
QID=$(echo "$PAYLOAD" | jq -r '.payload.question_id')
SKILL=$(echo "$PAYLOAD" | jq -r '.payload.skill')
QUESTION=$(echo "$PAYLOAD" | jq -r '.payload.question')
OPTS=$(echo "$PAYLOAD" | jq -r '.payload.options | length')
CTX=$(echo "$PAYLOAD" | jq -r '.payload.context_excerpt')
assert_eq "case-1-type" "skill-question" "$TYPE"
assert_eq "case-1-question_id" "q-abc" "$QID"
assert_eq "case-1-skill" "superpowers:writing-plans" "$SKILL"
assert_eq "case-1-question" "Q?" "$QUESTION"
assert_eq "case-1-options-count" "2" "$OPTS"
assert_eq "case-1-context-present" "ctx" "$CTX"

# Case 2: skill-answer in_reply_to correlation.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
build_skill_question "senior-developer-001" "q-1" "superpowers:writing-plans" "Q?" '["a","b"]' "ctx" >> "$BUS"
build_skill_answer "manager-001" "senior-developer-001" "a" "q-1" >> "$BUS"
ANSWER=$(poll_for_answer "$BUS" "q-1")
assert_eq "case-2-answer-correlated" "a" "$ANSWER"
rm -rf "$DIR"

# Case 3: non-matching in_reply_to is ignored.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
build_skill_question "senior-developer-001" "q-1" "superpowers:writing-plans" "Q?" '["a","b"]' "ctx" >> "$BUS"
build_skill_answer "manager-001" "senior-developer-001" "wrong" "q-2" >> "$BUS"
ANSWER=$(poll_for_answer "$BUS" "q-1")
assert_eq "case-3-non-matching-ignored" "" "$ANSWER"
rm -rf "$DIR"

# Case 4: M relay attribution shape.
HEADER=$(m_relay_header "senior-developer-20260502T122205-64ee18" "superpowers:writing-plans")
assert_eq "case-4-attribution-sd" "from senior-developer via skill superpowers:writing-plans" "$HEADER"
HEADER=$(m_relay_header "pair-programmer-20260502T122158-796827" "superpowers:requesting-code-review")
assert_eq "case-4-attribution-pp" "from pair-programmer via skill superpowers:requesting-code-review" "$HEADER"
HEADER=$(m_relay_header "tester-20260502T122154-f848b3" "superpowers:systematic-debugging")
assert_eq "case-4-attribution-t" "from tester via skill superpowers:systematic-debugging" "$HEADER"

# Case 5: timeout returns empty (peer's poll loop exits without answer).
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
: > "$BUS"
# Simulate the poll-with-timeout pattern: 2-iteration loop, no answer.
DEADLINE=$(( $(date +%s) + 2 ))
ANSWER=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  ANSWER=$(poll_for_answer "$BUS" "q-1")
  [ -n "$ANSWER" ] && break
  sleep 1
done
assert_eq "case-5-timeout-empty-result" "" "$ANSWER"
rm -rf "$DIR"

# Case 6: multi-question isolation (no cross-correlation).
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
build_skill_question "senior-developer-001" "q-A" "superpowers:writing-plans" "QA?" '["a1"]' "ctxA" >> "$BUS"
build_skill_question "senior-developer-001" "q-B" "superpowers:test-driven-development" "QB?" '["b1"]' "ctxB" >> "$BUS"
build_skill_answer "manager-001" "senior-developer-001" "answer-A" "q-A" >> "$BUS"
build_skill_answer "manager-001" "senior-developer-001" "answer-B" "q-B" >> "$BUS"
A_ANS=$(poll_for_answer "$BUS" "q-A")
B_ANS=$(poll_for_answer "$BUS" "q-B")
assert_eq "case-6-q-A-isolated" "answer-A" "$A_ANS"
assert_eq "case-6-q-B-isolated" "answer-B" "$B_ANS"
rm -rf "$DIR"

# Case 7: pre-approved skill list per role (each peer file has the expected count).
PP_COUNT=$(grep -cE '^- `superpowers:(requesting-code-review|receiving-code-review|verification-before-completion)`' "$ROOT/commands/pair-programmer.md")
SD_COUNT=$(grep -cE '^- `(superpowers:writing-plans|superpowers:test-driven-development|superpowers:systematic-debugging|superpowers:executing-plans|frontend-design:frontend-design)`' "$ROOT/commands/senior-developer.md")
T_COUNT=$(grep -cE '^- `superpowers:(test-driven-development|systematic-debugging|verification-before-completion)`' "$ROOT/commands/tester.md")
assert_eq "case-7-pp-skill-count" "3" "$PP_COUNT"
assert_eq "case-7-sd-skill-count" "5" "$SD_COUNT"
assert_eq "case-7-t-skill-count" "3" "$T_COUNT"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "superpowers-relay: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
