#!/usr/bin/env bash
# Story 138 (backlog 159) — M's sprint-pace status payload surfaces the
# IDs of items dispatched-but-not-yet-started. Closes the 4hr-miss class
# (sprint 2026-05-18 story 111 sat untouched).
#
# Test extracts the unstarted-dispatched recipe LITERALLY from
# commands/manager.md between sentinel comments
# `# UNSTARTED-DISPATCHED-RECIPE-START` / `# UNSTARTED-DISPATCHED-RECIPE-END`,
# then `eval`s it against three fixtures. Doctrine and test never drift.

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

assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANAGER_MD="$TEST_ROOT/commands/manager.md"

# ---- Extract the doctrine recipe verbatim. ----
RECIPE=$(awk '/# UNSTARTED-DISPATCHED-RECIPE-START/,/# UNSTARTED-DISPATCHED-RECIPE-END/' "$MANAGER_MD")
if [ -z "$RECIPE" ]; then
  echo "manager-pace-status-unstarted-dispatched: FAIL — recipe sentinels not found in $MANAGER_MD" >&2
  exit 1
fi

# ---- Doc-shape sub-assertion: doctrine names the field + sentinels. ----
DOC_BODY=$(cat "$MANAGER_MD")
assert_contains "doc-mentions-unstarted-dispatched"      "unstarted_dispatched" "$DOC_BODY"
assert_contains "doc-has-recipe-start-sentinel"          "# UNSTARTED-DISPATCHED-RECIPE-START" "$DOC_BODY"
assert_contains "doc-has-recipe-end-sentinel"            "# UNSTARTED-DISPATCHED-RECIPE-END" "$DOC_BODY"

# ---- Fixture helpers ----
write_manifest_3_dispatched() {
  # Real manifest-item shape (FINDING-37): items carry `id` + a `story` path,
  # NOT a `story_id` (and `id` i1/i2/i3 is deliberately NOT the story number —
  # the recipe derives s1/s2/s3 from the `story` path basename prefix). The
  # fixture used to carry a `story_id` the real manifest lacks, which masked
  # the inert recipe; this shape would have caught FINDING-37.
  local dir="$1"
  cat > "$dir/manifest.json" <<'JSON'
{
  "id": "fixture-sprint",
  "concurrency_limit": 3,
  "items": [
    {"id": "i1", "story": "implementations/stories/s1-alpha.md", "status": "dispatched"},
    {"id": "i2", "story": "implementations/stories/s2-beta.md", "status": "dispatched"},
    {"id": "i3", "story": "implementations/stories/s3-gamma.md", "status": "dispatched"}
  ]
}
JSON
}

emit_bus_object_payload() {
  # emit_bus_object_payload <bus-file> <type> <story_id>
  local bus="$1" type="$2" sid="$3"
  jq -cn --arg type "$type" --arg sid "$sid" \
    '{ts:"2026-05-21T12:00:00Z", from:"senior-developer-XXX", to:"pair-programmer-*", type:$type, payload:{story_id:$sid}}' \
    >> "$bus"
}

emit_bus_string_payload() {
  # emit_bus_string_payload <bus-file> <type> <story_id>
  local bus="$1" type="$2" sid="$3"
  local payload
  payload=$(jq -cn --arg sid "$sid" '{story_id:$sid}')
  jq -cn --arg type "$type" --arg p "$payload" \
    '{ts:"2026-05-21T12:01:00Z", from:"senior-developer-XXX", to:"pair-programmer-*", type:$type, payload:$p}' \
    >> "$bus"
}

run_recipe() {
  # run_recipe <fixture-dir>
  # ROOT must point to fixture-dir; MANIFEST must point to the manifest.json.
  # Returns the recipe's UNSTARTED_DISPATCHED value via stdout.
  local dir="$1"
  ROOT="$dir" MANIFEST="$dir/manifest.json" bash -c "
    set -u
    $RECIPE
    printf '%s' \"\$UNSTARTED_DISPATCHED\"
  "
}

# ---- (a) Mixed fixture — s1 has object-payload plan-done, s2 has stringified
#         plan-ready-for-review, s3 has nothing. Expect [\"s3\"]. ----
PA=$(mktemp -d)
mkdir -p "$PA/implementations"
BUS_A="$PA/implementations/.message-bus.jsonl"
touch "$BUS_A"
emit_bus_object_payload  "$BUS_A" "plan-done"               "s1"
emit_bus_string_payload  "$BUS_A" "plan-ready-for-review"   "s2"
write_manifest_3_dispatched "$PA"
OUT_A=$(run_recipe "$PA")
assert_eq "a-mixed-fixture-s3-only" '["s3"]' "$OUT_A"
rm -rf "$PA"

# ---- (b) Stringified-only fixture — every SD emit uses stringified payload.
#         s1 + s2 have activity (string), s3 has none. Expect [\"s3\"]. ----
PB=$(mktemp -d)
mkdir -p "$PB/implementations"
BUS_B="$PB/implementations/.message-bus.jsonl"
touch "$BUS_B"
emit_bus_string_payload  "$BUS_B" "plan-done"             "s1"
emit_bus_string_payload  "$BUS_B" "story-done"            "s2"
write_manifest_3_dispatched "$PB"
OUT_B=$(run_recipe "$PB")
assert_eq "b-stringified-only-s3-only" '["s3"]' "$OUT_B"
rm -rf "$PB"

# ---- (c) Empty-bus fixture — no SD activity at all. All 3 unstarted.
#         Order in the output reflects manifest iteration order. ----
PC=$(mktemp -d)
mkdir -p "$PC/implementations"
touch "$PC/implementations/.message-bus.jsonl"
write_manifest_3_dispatched "$PC"
OUT_C=$(run_recipe "$PC")
assert_eq "c-empty-bus-all-three" '["s1","s2","s3"]' "$OUT_C"
rm -rf "$PC"

# Story 141 — reference adoption: the manifest-item fixture validates against
# the golden set (would catch a future drift back to story_id).
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")" && pwd)/lib/contract-golden.sh"
if assert_fixture_matches_golden manifest-item '{"id":"i1","story":"implementations/stories/s1-alpha.md","status":"dispatched"}' 2>/dev/null; then
  PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("141-golden: manifest-item fixture diverges from golden"); fi

echo "manager-pace-status-unstarted-dispatched: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
