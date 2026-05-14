#!/usr/bin/env bash
# Story 035 — humanize_steps payload + M relay logic test.
#
# Asserts:
#  - story-verified payload may carry humanize_steps array
#  - relay logic correctly handles present/absent/empty cases
#  - sprint-mode aggregation orders by item_id with [item NNN] prefix
#  - malformed entries are surfaced (not silently dropped)
#  - field is only meaningful on story-verified messages

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

# Inline mirror of M's relay decision: "should-relay" if humanize_steps
# is non-empty array; "no-relay" otherwise (absent or empty).
should_relay() {
  local payload_json="$1"
  local count
  count=$(printf '%s' "$payload_json" | jq -r '.humanize_steps // [] | length')
  if [ "$count" -gt 0 ]; then echo "should-relay"; else echo "no-relay"; fi
}

# Aggregate humanize_steps from a sprint's bus, ordered by item_id.
# Returns one line per item with steps, prefixed `[item NNN]`.
aggregate_sprint() {
  local bus="$1" sprint="$2"
  jq -r --arg sprint "$sprint" '
    select(.type == "story-verified")
    | select(.sprint_id == $sprint)
    | select(.payload.humanize_steps // [] | length > 0)
    | "[item \(.item_id)] " + (.payload.humanize_steps | map(.do) | join("; "))
  ' "$bus" 2>/dev/null | sort
}

# Validate one humanize step entry — return "ok" or "malformed".
validate_entry() {
  local entry_json="$1"
  local has_do has_expect
  has_do=$(printf '%s' "$entry_json" | jq -r 'has("do")')
  has_expect=$(printf '%s' "$entry_json" | jq -r 'has("expect")')
  if [ "$has_do" = "true" ] && [ "$has_expect" = "true" ]; then
    echo "ok"
  else
    echo "malformed"
  fi
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: payload assembly with humanize_steps — jq parses each field.
PAYLOAD='{"sha":"abc","humanize_steps":[{"step":1,"do":"X","expect":"Y"}]}'
STEP_DO=$(printf '%s' "$PAYLOAD" | jq -r '.humanize_steps[0].do')
STEP_EXPECT=$(printf '%s' "$PAYLOAD" | jq -r '.humanize_steps[0].expect')
STEP_NUM=$(printf '%s' "$PAYLOAD" | jq -r '.humanize_steps[0].step')
assert_eq "case-1-do-parsed" "X" "$STEP_DO"
assert_eq "case-1-expect-parsed" "Y" "$STEP_EXPECT"
assert_eq "case-1-step-parsed" "1" "$STEP_NUM"

# Case 2: missing field treated as no-relay.
PAYLOAD='{"sha":"abc"}'
assert_eq "case-2-missing-no-relay" "no-relay" "$(should_relay "$PAYLOAD")"

# Case 3: empty array treated as no-relay.
PAYLOAD='{"sha":"abc","humanize_steps":[]}'
assert_eq "case-3-empty-no-relay" "no-relay" "$(should_relay "$PAYLOAD")"

# Case 4: sprint aggregation orders by item_id with [item NNN] prefix.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T08:00:00Z","from":"t","to":"manager-*","type":"story-verified","sprint_id":"S","item_id":"027","payload":{"humanize_steps":[{"step":1,"do":"check-027","expect":"ok"}]}}
{"ts":"2026-05-02T08:01:00Z","from":"t","to":"manager-*","type":"story-verified","sprint_id":"S","item_id":"030","payload":{"humanize_steps":[{"step":1,"do":"check-030","expect":"ok"}]}}
{"ts":"2026-05-02T08:02:00Z","from":"t","to":"manager-*","type":"story-verified","sprint_id":"S","item_id":"029","payload":{"sha":"abc"}}
EOF
RESULT=$(aggregate_sprint "$BUS" "S")
COUNT=$(printf '%s\n' "$RESULT" | grep -c '^\[item ' || true)
assert_eq "case-4-aggregated-count" "2" "$COUNT"
FIRST=$(printf '%s\n' "$RESULT" | head -1)
case "$FIRST" in
  '[item 027]'*) assert_eq "case-4-first-item-is-027" "yes" "yes" ;;
  *) assert_eq "case-4-first-item-is-027" "yes" "no (got: $FIRST)" ;;
esac
SECOND=$(printf '%s\n' "$RESULT" | sed -n 2p)
case "$SECOND" in
  '[item 030]'*) assert_eq "case-4-second-item-is-030" "yes" "yes" ;;
  *) assert_eq "case-4-second-item-is-030" "yes" "no (got: $SECOND)" ;;
esac
rm -rf "$DIR"

# Case 5: payload field validation — missing `do` flagged malformed.
ENTRY='{"step":1,"expect":"Y"}'
assert_eq "case-5-missing-do-malformed" "malformed" "$(validate_entry "$ENTRY")"

ENTRY='{"step":1,"do":"X"}'
assert_eq "case-5-missing-expect-malformed" "malformed" "$(validate_entry "$ENTRY")"

ENTRY='{"step":1,"do":"X","expect":"Y"}'
assert_eq "case-5-complete-ok" "ok" "$(validate_entry "$ENTRY")"

# Case 6: T → M → human routing — humanize_steps appears only on
# story-verified messages from T to manager-*. Synthetic check that the
# convention holds in the bus filter.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T08:00:00Z","from":"t","to":"manager-*","type":"story-verified","payload":{"humanize_steps":[{"step":1,"do":"X","expect":"Y"}]}}
{"ts":"2026-05-02T08:01:00Z","from":"t","to":"*","type":"status","payload":{"humanize_steps":[{"step":1,"do":"WRONG","expect":"WRONG"}]}}
EOF
# Filter: only count humanize_steps on story-verified to manager-*.
COUNT=$(jq -r 'select(.type=="story-verified" and (.to == "manager-*" or (.to | startswith("manager-")))) | .payload.humanize_steps // [] | length' "$BUS" | awk '{s+=$1} END{print s+0}')
assert_eq "case-6-routing-only-counts-story-verified" "1" "$COUNT"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "humanize-testing-steps: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
