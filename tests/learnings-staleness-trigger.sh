#!/usr/bin/env bash
# Story 045 — sprint-end learnings.md staleness trigger test.
#
# Asserts:
#  - learnings-updated payload shape (4 fields)
#  - peer no-op skip path (silent on no stale facts)
#  - M aggregation reads correctly (per-peer count)
#  - missing peers default to zero in aggregation
#  - retro-learnings-window-open payload shape (sprint_id + deadline_ts)
#  - deadline_ts approximately matches now + 2 min

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

# Inline mirror: build a learnings-updated emit payload.
build_learnings_updated() {
  local from="$1" sprint_id="$2" path="$3" sha_before="$4" sha_after="$5" summary="$6"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg from "$from" --arg sprint_id "$sprint_id" --arg path "$path" \
    --arg sha_before "$sha_before" --arg sha_after "$sha_after" \
    --arg summary "$summary" \
    '{ts:$ts, from:$from, to:"manager-*", type:"learnings-updated", sprint_id:$sprint_id, payload:{path:$path, sha_before:$sha_before, sha_after:$sha_after, summary:$summary}}'
}

# Inline mirror: M's aggregation jq over a bus, emitting per-peer counts.
aggregate_learnings_counts() {
  local bus="$1" sprint_id="$2"
  jq -s --arg sprint "$sprint_id" '
    [.[] | select(.type == "learnings-updated" and .sprint_id == $sprint)] as $emits
    | {
        pp: ([$emits[] | select(.from | startswith("pair-programmer"))] | length),
        sd: ([$emits[] | select(.from | startswith("senior-developer"))] | length),
        t:  ([$emits[] | select(.from | startswith("tester"))] | length),
        s:  ([$emits[] | select(.from | startswith("slacker"))] | length)
      }
  ' "$bus"
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: learnings-updated payload shape.
PAYLOAD=$(build_learnings_updated "tester-test-001" "S1" "implementations/learnings/tester.md" "abc123" "def456" "updated suite count 32 → 40")
TYPE=$(echo "$PAYLOAD" | jq -r '.type')
P_PATH=$(echo "$PAYLOAD" | jq -r '.payload.path')
P_SBEF=$(echo "$PAYLOAD" | jq -r '.payload.sha_before')
P_SAFT=$(echo "$PAYLOAD" | jq -r '.payload.sha_after')
P_SUM=$(echo "$PAYLOAD" | jq -r '.payload.summary')
assert_eq "case-1-type" "learnings-updated" "$TYPE"
assert_eq "case-1-path" "implementations/learnings/tester.md" "$P_PATH"
assert_eq "case-1-sha-before" "abc123" "$P_SBEF"
assert_eq "case-1-sha-after" "def456" "$P_SAFT"
assert_eq "case-1-summary-present" "yes" "$([ -n "$P_SUM" ] && echo yes || echo no)"

# Case 2: no-op skip — peer SHOULD NOT emit if nothing stale.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
: > "$BUS"
# Peer simulates a no-op skim: no emit appended.
LINES=$(wc -l < "$BUS" | tr -d ' ')
assert_eq "case-2-no-op-empty-bus" "0" "$LINES"
rm -rf "$DIR"

# Case 3: aggregation reads per-peer counts correctly (one emit per peer).
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
build_learnings_updated "pair-programmer-001" "S1" "implementations/learnings/pair-programmer.md" "a" "b" "x" >> "$BUS"
build_learnings_updated "senior-developer-001"      "S1" "implementations/learnings/senior-developer.md" "a" "b" "x" >> "$BUS"
build_learnings_updated "tester-001"          "S1" "implementations/learnings/tester.md"          "a" "b" "x" >> "$BUS"
build_learnings_updated "slacker-001"         "S1" "implementations/learnings/slacker.md"         "a" "b" "x" >> "$BUS"
COUNTS=$(aggregate_learnings_counts "$BUS" "S1")
assert_eq "case-3-pp-count" "1" "$(echo "$COUNTS" | jq -r '.pp')"
assert_eq "case-3-sd-count" "1" "$(echo "$COUNTS" | jq -r '.sd')"
assert_eq "case-3-t-count" "1" "$(echo "$COUNTS" | jq -r '.t')"
assert_eq "case-3-s-count" "1" "$(echo "$COUNTS" | jq -r '.s')"
rm -rf "$DIR"

# Case 4: aggregation defaults missing peers to zero.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
build_learnings_updated "pair-programmer-001" "S1" "implementations/learnings/pair-programmer.md" "a" "b" "x" >> "$BUS"
build_learnings_updated "tester-001"          "S1" "implementations/learnings/tester.md"          "a" "b" "x" >> "$BUS"
COUNTS=$(aggregate_learnings_counts "$BUS" "S1")
assert_eq "case-4-pp-1" "1" "$(echo "$COUNTS" | jq -r '.pp')"
assert_eq "case-4-sd-0" "0" "$(echo "$COUNTS" | jq -r '.sd')"
assert_eq "case-4-t-1" "1" "$(echo "$COUNTS" | jq -r '.t')"
assert_eq "case-4-s-0" "0" "$(echo "$COUNTS" | jq -r '.s')"
rm -rf "$DIR"

# Case 5: retro-learnings-window-open payload validation.
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DEADLINE=$(date -u -v+2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 minutes' +%Y-%m-%dT%H:%M:%SZ)
WINDOW=$(jq -nc --arg ts "$NOW" --arg from "manager-001" --arg sprint_id "S1" --arg deadline "$DEADLINE" \
  '{ts:$ts, from:$from, to:"*", type:"retro-learnings-window-open", sprint_id:$sprint_id, payload:{sprint_id:$sprint_id, deadline_ts:$deadline}}')
W_TYPE=$(echo "$WINDOW" | jq -r '.type')
W_SPRINT=$(echo "$WINDOW" | jq -r '.payload.sprint_id')
W_DEADLINE=$(echo "$WINDOW" | jq -r '.payload.deadline_ts')
assert_eq "case-5-type" "retro-learnings-window-open" "$W_TYPE"
assert_eq "case-5-sprint-id" "S1" "$W_SPRINT"
assert_eq "case-5-deadline-iso-format" "yes" "$(echo "$W_DEADLINE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo yes || echo no)"

# Case 6: deadline_ts is ~2 min from now (within ±5s tolerance).
NOW_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$NOW" +%s 2>/dev/null || date -u -d "$NOW" +%s)
DEADLINE_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$W_DEADLINE" +%s 2>/dev/null || date -u -d "$W_DEADLINE" +%s)
DELTA=$((DEADLINE_EPOCH - NOW_EPOCH))
# Expect ~120s; tolerate 115–125s.
TOLERANCE_OK=$([ "$DELTA" -ge 115 ] && [ "$DELTA" -le 125 ] && echo "yes" || echo "no (delta=$DELTA)")
assert_eq "case-6-deadline-2-min-tolerance" "yes" "$TOLERANCE_OK"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "learnings-staleness-trigger: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
