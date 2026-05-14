#!/usr/bin/env bash
# Story 050 — superpowers e2e protocol round-trip test.
#
# Stubs Skill invocation and AskUserQuestion entirely. Asserts the bus
# protocol round-trip including peer's emit, M's relay (attribution +
# skill-answer emit), peer's poll, multi-question isolation, timeout,
# non-question pass-through, and malformed-payload handling.

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

# Build skill-question payload (mirrors role-file bash example).
build_skill_question() {
  local from="$1" q_id="$2" skill="$3" question="$4" options_json="$5" ctx="$6"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg from "$from" --arg q_id "$q_id" --arg skill "$skill" \
    --arg question "$question" --argjson options "$options_json" --arg ctx "$ctx" \
    '{ts:$ts, from:$from, to:"manager-*", type:"skill-question", payload:{question_id:$q_id, skill:$skill, question:$question, options:$options, context_excerpt:$ctx}}'
}

# Build skill-answer (M side).
build_skill_answer() {
  local from="$1" to="$2" answer="$3" in_reply_to="$4"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg from "$from" --arg to "$to" --arg answer "$answer" --arg in_reply_to "$in_reply_to" \
    '{ts:$ts, from:$from, to:$to, type:"skill-answer", payload:{answer:$answer, in_reply_to:$in_reply_to}}'
}

# Mirror M's role-extraction from peer agent ID.
m_extract_role() {
  local agent_id="$1"
  case "$agent_id" in
    pair-programmer-*) echo "pair-programmer" ;;
    senior-developer-*) echo "senior-developer" ;;
    tester-*) echo "tester" ;;
    slacker-*) echo "slacker" ;;
    *) echo "unknown" ;;
  esac
}

m_relay_header() {
  local agent_id="$1" skill="$2"
  local role; role=$(m_extract_role "$agent_id")
  echo "from $role via skill $skill"
}

# Mirror peer's poll.
poll_for_answer() {
  local bus="$1" q_id="$2"
  jq -r --arg q_id "$q_id" 'select(.type == "skill-answer" and .payload.in_reply_to == $q_id) | .payload.answer' "$bus" 2>/dev/null | head -1
}

# Mirror M's malformed-payload validation.
m_validate_skill_question() {
  local payload_json="$1"
  local q_id; q_id=$(echo "$payload_json" | jq -r '.payload.question_id // empty')
  local skill; skill=$(echo "$payload_json" | jq -r '.payload.skill // empty')
  local question; question=$(echo "$payload_json" | jq -r '.payload.question // empty')
  if [ -z "$q_id" ] || [ -z "$skill" ] || [ -z "$question" ]; then
    echo "malformed"
  else
    echo "ok"
  fi
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: full round-trip — peer emit → M relay → answer → resumption.
DIR=$(mktemp -d); BUS="$DIR/bus.jsonl"
build_skill_question "senior-developer-001" "q-1" "superpowers:writing-plans" "Q?" '["a","b"]' "ctx" >> "$BUS"
# M relay: read q-1 + emit skill-answer.
build_skill_answer "manager-001" "senior-developer-001" "a" "q-1" >> "$BUS"
ANSWER=$(poll_for_answer "$BUS" "q-1")
assert_eq "case-1-roundtrip" "a" "$ANSWER"
rm -rf "$DIR"

# Case 2: M attribution for PP.
HEADER=$(m_relay_header "pair-programmer-20260502T122158-796827" "superpowers:requesting-code-review")
assert_eq "case-2-attribution-pp" "from pair-programmer via skill superpowers:requesting-code-review" "$HEADER"

# Case 3: M attribution for SD.
HEADER=$(m_relay_header "senior-developer-20260502T122205-64ee18" "superpowers:writing-plans")
assert_eq "case-3-attribution-sd" "from senior-developer via skill superpowers:writing-plans" "$HEADER"

# Case 4: M attribution for T.
HEADER=$(m_relay_header "tester-20260502T122154-f848b3" "superpowers:test-driven-development")
assert_eq "case-4-attribution-t" "from tester via skill superpowers:test-driven-development" "$HEADER"

# Case 5: M attribution for S.
HEADER=$(m_relay_header "slacker-20260502T122744-f4baa1" "superpowers:writing-plans")
assert_eq "case-5-attribution-s" "from slacker via skill superpowers:writing-plans" "$HEADER"

# Case 6: 3 concurrent peer questions resolve independently.
DIR=$(mktemp -d); BUS="$DIR/bus.jsonl"
build_skill_question "pair-programmer-001" "q-A" "superpowers:requesting-code-review" "QA?" '["pa1"]' "ctxA" >> "$BUS"
build_skill_question "senior-developer-001" "q-B" "superpowers:writing-plans" "QB?" '["sb1"]' "ctxB" >> "$BUS"
build_skill_question "tester-001" "q-C" "superpowers:test-driven-development" "QC?" '["tc1"]' "ctxC" >> "$BUS"
# M emits answers in arbitrary order.
build_skill_answer "manager-001" "tester-001" "answer-C" "q-C" >> "$BUS"
build_skill_answer "manager-001" "pair-programmer-001" "answer-A" "q-A" >> "$BUS"
build_skill_answer "manager-001" "senior-developer-001" "answer-B" "q-B" >> "$BUS"
A_ANS=$(poll_for_answer "$BUS" "q-A")
B_ANS=$(poll_for_answer "$BUS" "q-B")
C_ANS=$(poll_for_answer "$BUS" "q-C")
assert_eq "case-6-q-A-isolated" "answer-A" "$A_ANS"
assert_eq "case-6-q-B-isolated" "answer-B" "$B_ANS"
assert_eq "case-6-q-C-isolated" "answer-C" "$C_ANS"
rm -rf "$DIR"

# Case 7: timeout cleanly returns no-answer.
DIR=$(mktemp -d); BUS="$DIR/bus.jsonl"
: > "$BUS"
DEADLINE=$(( $(date +%s) + 2 ))
ANSWER=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  ANSWER=$(poll_for_answer "$BUS" "q-1")
  [ -n "$ANSWER" ] && break
  sleep 1
done
assert_eq "case-7-timeout-no-answer" "" "$ANSWER"
rm -rf "$DIR"

# Case 8: non-question peer output passes through (no skill-question emitted).
DIR=$(mktemp -d); BUS="$DIR/bus.jsonl"
# Peer emits status (not skill-question) — bus never sees a skill-question line.
jq -nc '{ts:"t",from:"senior-developer-001",to:"manager-*",type:"status",payload:"working on plan"}' >> "$BUS"
SKILL_Q_COUNT=$(jq -s '[.[] | select(.type == "skill-question")] | length' "$BUS")
assert_eq "case-8-no-skill-question-on-status" "0" "$SKILL_Q_COUNT"
rm -rf "$DIR"

# Case 9: malformed payload (missing question_id) detected.
DIR=$(mktemp -d); BUS="$DIR/bus.jsonl"
# Build a malformed skill-question (no question_id field).
MALFORMED=$(jq -nc '{ts:"t",from:"senior-developer-001",to:"manager-*",type:"skill-question",payload:{skill:"superpowers:writing-plans",question:"Q?",options:["a"],context_excerpt:"ctx"}}')
echo "$MALFORMED" >> "$BUS"
RESULT=$(m_validate_skill_question "$MALFORMED")
assert_eq "case-9-malformed-detected" "malformed" "$RESULT"
# Verify a well-formed one passes validation
WELLFORMED=$(build_skill_question "senior-developer-001" "q-1" "superpowers:writing-plans" "Q?" '["a"]' "ctx")
RESULT=$(m_validate_skill_question "$WELLFORMED")
assert_eq "case-9-wellformed-passes" "ok" "$RESULT"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "superpowers-e2e: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
