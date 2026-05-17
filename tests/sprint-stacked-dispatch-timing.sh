#!/usr/bin/env bash
# Story 022 — sprint-graph-next-dispatchable plan-approved gate test.
#
# The script's stacked-child gate is the proxy for "M creates the child's
# branch+worktree from the parent's tip at parent plan-approved time" —
# the M-side prompt-driven behavior is what actually creates the branches,
# but this script gates which children appear in the dispatchable list.
# When the parent's plan_approved_at is null, the child should NOT appear
# even if the parent's status meets the dispatched/in-review/merged check.

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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/sprint-graph-next-dispatchable.sh"
[ -x "$SCRIPT" ] || { echo "ERROR: $SCRIPT not executable" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Fixture builder
# -----------------------------------------------------------------------------

# manifest_with_parent_child <fixture-dir> <parent-status> <parent-plan-approved-at> <child-status>
manifest_with_parent_child() {
  local dir="$1" parent_status="$2" parent_plan_approved="$3" child_status="$4"
  local manifest="$dir/manifest.json"
  local plan_approved_json
  if [ "$parent_plan_approved" = "null" ]; then
    plan_approved_json="null"
  else
    plan_approved_json="\"$parent_plan_approved\""
  fi
  cat > "$manifest" <<JSON
{
  "sprint_id": "test-sprint",
  "concurrency_limit": 3,
  "items": [
    {
      "id": "001",
      "story": "x",
      "depends_on": [],
      "branch": "feat/001-parent",
      "plan_approved_at": $plan_approved_json,
      "status": "$parent_status"
    },
    {
      "id": "002",
      "story": "y",
      "depends_on": ["001"],
      "branch": "feat/002-child",
      "stacked_on": "feat/001-parent",
      "plan_approved_at": null,
      "status": "$child_status"
    }
  ]
}
JSON
  echo "$manifest"
}

# manifest_independent <fixture-dir> <status>
manifest_independent() {
  local dir="$1" status="$2"
  local manifest="$dir/manifest.json"
  cat > "$manifest" <<JSON
{
  "sprint_id": "test-sprint",
  "concurrency_limit": 3,
  "items": [
    {
      "id": "100",
      "story": "x",
      "depends_on": [],
      "branch": "feat/100-indep",
      "plan_approved_at": null,
      "status": "$status"
    }
  ]
}
JSON
  echo "$manifest"
}

# manifest_chain <fixture-dir> — A→B→C; A.plan_approved_at, B.plan_approved_at can be set
manifest_chain() {
  local dir="$1" a_plan_approved="$2" b_plan_approved="$3" a_status="$4" b_status="$5"
  local manifest="$dir/manifest.json"
  local a_pa b_pa
  if [ "$a_plan_approved" = "null" ]; then a_pa="null"; else a_pa="\"$a_plan_approved\""; fi
  if [ "$b_plan_approved" = "null" ]; then b_pa="null"; else b_pa="\"$b_plan_approved\""; fi
  cat > "$manifest" <<JSON
{
  "sprint_id": "test-sprint",
  "concurrency_limit": 5,
  "items": [
    {"id":"A","story":"a","depends_on":[],"branch":"feat/A","plan_approved_at":$a_pa,"status":"$a_status"},
    {"id":"B","story":"b","depends_on":["A"],"branch":"feat/B","stacked_on":"feat/A","plan_approved_at":$b_pa,"status":"$b_status"},
    {"id":"C","story":"c","depends_on":["B"],"branch":"feat/C","stacked_on":"feat/B","plan_approved_at":null,"status":"pending"}
  ]
}
JSON
  echo "$manifest"
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: parent dispatched but plan_approved_at is null → child NOT dispatchable.
DIR=$(mktemp -d)
M=$(manifest_with_parent_child "$DIR" "dispatched" "null" "pending")
OUT=$(bash "$SCRIPT" "$M" | tr '\n' ' ' | sed 's/ $//')
case " $OUT " in
  *" 002 "*) assert_eq "case-1-child-not-dispatchable-without-plan-approved" "no" "yes" ;;
  *)        assert_eq "case-1-child-not-dispatchable-without-plan-approved" "no" "no" ;;
esac
rm -rf "$DIR"

# Case 2: parent dispatched + plan_approved_at set → child IS dispatchable.
DIR=$(mktemp -d)
M=$(manifest_with_parent_child "$DIR" "dispatched" "2026-05-02T06:00:00Z" "pending")
OUT=$(bash "$SCRIPT" "$M" | tr '\n' ' ' | sed 's/ $//')
case " $OUT " in
  *" 002 "*) assert_eq "case-2-child-dispatchable-with-plan-approved" "yes" "yes" ;;
  *)        assert_eq "case-2-child-dispatchable-with-plan-approved" "yes" "no" ;;
esac
rm -rf "$DIR"

# Case 3: independent item still dispatchable immediately (regression guard).
DIR=$(mktemp -d)
M=$(manifest_independent "$DIR" "pending")
OUT=$(bash "$SCRIPT" "$M" | tr '\n' ' ' | sed 's/ $//')
case " $OUT " in
  *" 100 "*) assert_eq "case-3-independent-still-dispatchable" "yes" "yes" ;;
  *)        assert_eq "case-3-independent-still-dispatchable" "yes" "no" ;;
esac
rm -rf "$DIR"

# Case 4: parent merged but plan_approved_at null → child NOT dispatchable
# (defensive: gate is conjunctive — both status check AND plan_approved gate must pass).
DIR=$(mktemp -d)
M=$(manifest_with_parent_child "$DIR" "merged" "null" "pending")
OUT=$(bash "$SCRIPT" "$M" | tr '\n' ' ' | sed 's/ $//')
case " $OUT " in
  *" 002 "*) assert_eq "case-4-merged-but-no-plan-approved" "no" "yes" ;;
  *)        assert_eq "case-4-merged-but-no-plan-approved" "no" "no" ;;
esac
rm -rf "$DIR"

# Case 5: plan_approved_at set BUT parent.status pending → child NOT dispatchable
# (status check fails first; symmetric to case 4).
DIR=$(mktemp -d)
M=$(manifest_with_parent_child "$DIR" "pending" "2026-05-02T06:00:00Z" "pending")
OUT=$(bash "$SCRIPT" "$M" | tr '\n' ' ' | sed 's/ $//')
case " $OUT " in
  *" 002 "*) assert_eq "case-5-plan-approved-but-parent-pending" "no" "yes" ;;
  *)        assert_eq "case-5-plan-approved-but-parent-pending" "no" "no" ;;
esac
rm -rf "$DIR"

# Case 6: chain A → B → C. Set A.plan_approved_at, B still pending → only B dispatchable.
DIR=$(mktemp -d)
M=$(manifest_chain "$DIR" "2026-05-02T06:00:00Z" "null" "dispatched" "pending")
OUT=$(bash "$SCRIPT" "$M" | tr '\n' ' ' | sed 's/ $//')
case " $OUT " in
  *" B "*) assert_eq "case-6-chain-B-dispatchable" "yes" "yes" ;;
  *)       assert_eq "case-6-chain-B-dispatchable" "yes" "no" ;;
esac
case " $OUT " in
  *" C "*) assert_eq "case-6-chain-C-not-dispatchable" "no" "yes" ;;
  *)       assert_eq "case-6-chain-C-not-dispatchable" "no" "no" ;;
esac
rm -rf "$DIR"

# Case 7: chain A → B → C. Set both A and B plan_approved_at; B dispatched too.
# Now C also becomes dispatchable.
DIR=$(mktemp -d)
M=$(manifest_chain "$DIR" "2026-05-02T06:00:00Z" "2026-05-02T07:00:00Z" "in-review" "dispatched")
OUT=$(bash "$SCRIPT" "$M" | tr '\n' ' ' | sed 's/ $//')
case " $OUT " in
  *" C "*) assert_eq "case-7-chain-C-dispatchable-after-B-plan-approved" "yes" "yes" ;;
  *)       assert_eq "case-7-chain-C-dispatchable-after-B-plan-approved" "yes" "no" ;;
esac
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "sprint-stacked-dispatch-timing: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
