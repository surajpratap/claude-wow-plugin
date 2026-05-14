#!/usr/bin/env bash
# Story 052 — pp-checkpoint payload shape lint.
#
# Asserts pp-checkpoint payloads carry the 4 required fields with correct
# types, and verifies the M-side ring-buffer trim-to-10 jq logic.
#
# Cases:
# 1. complete payload (all 4 fields, correct types) → valid
# 2. missing items_reviewed_so_far → invalid
# 3. missing open_reviews_now → invalid
# 4. missing last_finding_count_per_item → invalid
# 5. missing bus_cursor_line_number_observed → invalid
# 6. wrong type — items_reviewed_so_far as string → invalid
# 7. wrong type — bus_cursor_line_number_observed as string → invalid
# 8. wrong type — last_finding_count_per_item as array → invalid
# 9. ring-buffer trim — 11 checkpoints reduces to 10 (oldest dropped)
# 10. ring-buffer FIFO order — entry 1 dropped, entry 11 present, length 10

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

# Inline validator — mirrors what M's pp-checkpoint handler should run before
# persisting a checkpoint into tracker.pp_checkpoints.
validate_pp_checkpoint() {
  local payload_json="$1"
  local has t_irs t_orn t_lfc t_bcl
  for field in items_reviewed_so_far open_reviews_now last_finding_count_per_item bus_cursor_line_number_observed; do
    has=$(echo "$payload_json" | jq -r --arg f "$field" 'has($f)')
    [ "$has" = "true" ] || { echo "invalid:missing $field"; return 1; }
  done
  t_irs=$(echo "$payload_json" | jq -r '.items_reviewed_so_far | type')
  t_orn=$(echo "$payload_json" | jq -r '.open_reviews_now | type')
  t_lfc=$(echo "$payload_json" | jq -r '.last_finding_count_per_item | type')
  t_bcl=$(echo "$payload_json" | jq -r '.bus_cursor_line_number_observed | type')
  [ "$t_irs" = "array" ] || { echo "invalid:items_reviewed_so_far not array (got $t_irs)"; return 1; }
  [ "$t_orn" = "array" ] || { echo "invalid:open_reviews_now not array (got $t_orn)"; return 1; }
  [ "$t_lfc" = "object" ] || { echo "invalid:last_finding_count_per_item not object (got $t_lfc)"; return 1; }
  [ "$t_bcl" = "number" ] || { echo "invalid:bus_cursor_line_number_observed not number (got $t_bcl)"; return 1; }
  echo "valid"
  return 0
}

# Mirrors M's append-and-trim-to-10 jq logic for tracker.pp_checkpoints.
# Input: tracker JSON file path + new checkpoint JSON string.
# Output: updated tracker JSON written back to the same file.
ring_buffer_append() {
  local tracker_path="$1"
  local checkpoint_json="$2"
  jq --argjson cp "$checkpoint_json" \
    '.pp_checkpoints = ((.pp_checkpoints // []) + [$cp]) | .pp_checkpoints = (.pp_checkpoints | .[-10:])' \
    "$tracker_path" > "$tracker_path.tmp" && mv "$tracker_path.tmp" "$tracker_path"
}

# -----------------------------------------------------------------------------
# Case 1: complete payload — all 4 fields, correct types → valid
# -----------------------------------------------------------------------------
PAYLOAD_OK='{
  "items_reviewed_so_far": ["027", "029"],
  "open_reviews_now": ["050"],
  "last_finding_count_per_item": {"027": 0, "029": 1, "050": 2},
  "bus_cursor_line_number_observed": 1234
}'
assert_eq "case-1-complete-valid" "valid" "$(validate_pp_checkpoint "$PAYLOAD_OK" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Case 2: missing items_reviewed_so_far → invalid
# -----------------------------------------------------------------------------
P=$(echo "$PAYLOAD_OK" | jq 'del(.items_reviewed_so_far)')
assert_eq "case-2-missing-items_reviewed_so_far" \
  "invalid:missing items_reviewed_so_far" \
  "$(validate_pp_checkpoint "$P" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Case 3: missing open_reviews_now → invalid
# -----------------------------------------------------------------------------
P=$(echo "$PAYLOAD_OK" | jq 'del(.open_reviews_now)')
assert_eq "case-3-missing-open_reviews_now" \
  "invalid:missing open_reviews_now" \
  "$(validate_pp_checkpoint "$P" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Case 4: missing last_finding_count_per_item → invalid
# -----------------------------------------------------------------------------
P=$(echo "$PAYLOAD_OK" | jq 'del(.last_finding_count_per_item)')
assert_eq "case-4-missing-last_finding_count_per_item" \
  "invalid:missing last_finding_count_per_item" \
  "$(validate_pp_checkpoint "$P" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Case 5: missing bus_cursor_line_number_observed → invalid
# -----------------------------------------------------------------------------
P=$(echo "$PAYLOAD_OK" | jq 'del(.bus_cursor_line_number_observed)')
assert_eq "case-5-missing-bus_cursor_line_number_observed" \
  "invalid:missing bus_cursor_line_number_observed" \
  "$(validate_pp_checkpoint "$P" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Case 6: wrong type — items_reviewed_so_far as string → invalid
# -----------------------------------------------------------------------------
P=$(echo "$PAYLOAD_OK" | jq '.items_reviewed_so_far = "027,029"')
assert_eq "case-6-wrong-type-items-as-string" \
  "invalid:items_reviewed_so_far not array (got string)" \
  "$(validate_pp_checkpoint "$P" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Case 7: wrong type — bus_cursor_line_number_observed as string → invalid
# -----------------------------------------------------------------------------
P=$(echo "$PAYLOAD_OK" | jq '.bus_cursor_line_number_observed = "1234"')
assert_eq "case-7-wrong-type-cursor-as-string" \
  "invalid:bus_cursor_line_number_observed not number (got string)" \
  "$(validate_pp_checkpoint "$P" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Case 8: wrong type — last_finding_count_per_item as array → invalid
# -----------------------------------------------------------------------------
P=$(echo "$PAYLOAD_OK" | jq '.last_finding_count_per_item = []')
assert_eq "case-8-wrong-type-fcpi-as-array" \
  "invalid:last_finding_count_per_item not object (got array)" \
  "$(validate_pp_checkpoint "$P" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Case 9: ring-buffer accumulates correctly — 11 checkpoints trims to 10
# -----------------------------------------------------------------------------
DIR=$(mktemp -d)
TRACKER="$DIR/tracker.json"
echo '{}' > "$TRACKER"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  CP=$(jq -nc --argjson n "$i" \
    '{ts: ("2026-05-03T00:00:0\($n)Z"), sprint_id: "test-sprint", items_reviewed_so_far: [], open_reviews_now: [], last_finding_count_per_item: {}, bus_cursor_line_number_observed: $n, marker: $n}')
  ring_buffer_append "$TRACKER" "$CP"
done
LEN=$(jq -r '.pp_checkpoints | length' "$TRACKER")
assert_eq "case-9-ring-buffer-len-after-11-emits" "10" "$LEN"

# -----------------------------------------------------------------------------
# Case 10: ring-buffer FIFO — first dropped, last present, [0] is entry 2
# -----------------------------------------------------------------------------
HAS_ENTRY_1=$(jq -r '[.pp_checkpoints[].marker] | any(. == 1)' "$TRACKER")
HAS_ENTRY_11=$(jq -r '[.pp_checkpoints[].marker] | any(. == 11)' "$TRACKER")
HEAD_MARKER=$(jq -r '.pp_checkpoints[0].marker' "$TRACKER")
TAIL_MARKER=$(jq -r '.pp_checkpoints[9].marker' "$TRACKER")
assert_eq "case-10-fifo-entry-1-dropped" "false" "$HAS_ENTRY_1"
assert_eq "case-10-fifo-entry-11-present" "true" "$HAS_ENTRY_11"
assert_eq "case-10-fifo-head-is-entry-2" "2" "$HEAD_MARKER"
assert_eq "case-10-fifo-tail-is-entry-11" "11" "$TAIL_MARKER"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "pp-checkpoint-status-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
