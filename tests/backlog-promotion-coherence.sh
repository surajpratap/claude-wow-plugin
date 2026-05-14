#!/usr/bin/env bash
# Story 036 — backlog-promotion atomic helper + coherence-check test.
#
# Synthetic-fixture bash test mirroring tests/manager-pre-sleep-liveness.sh
# pattern. Per-case mktemp -d isolation. Tests the helper script and the
# coherence-check logic that M's startup uses.

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
SOURCE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
HELPER="$SOURCE_ROOT/scripts/file-story-from-backlog.sh"
[ -x "$HELPER" ] || { echo "ERROR: $HELPER not executable" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Inline coherence_check() helper — mirrors M's startup logic.
# Args: <fixture-dir>
# Echoes count of mismatches (backlog still `accepted` despite story filed).
# -----------------------------------------------------------------------------

coherence_check() {
  local fix="$1"
  local count=0
  for bf in "$fix/implementations/backlog/"*.md; do
    [ -f "$bf" ] || continue
    local st
    st=$(head -1 "$bf" | grep -oE 'status: [a-z-]+' | awk '{print $2}')
    [ "$st" != "accepted" ] && continue
    local basename_b
    basename_b=$(basename "$bf")
    # Look for any story file referencing this backlog
    if grep -lE "Source backlog: implementations/backlog/${basename_b}" "$fix/implementations/stories/"*.md 2>/dev/null | head -1 | grep -q .; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# -----------------------------------------------------------------------------
# Fixture builder
# -----------------------------------------------------------------------------

mk_fixture() {
  local dir; dir=$(mktemp -d)
  ( cd "$dir" && git init --quiet )
  mkdir -p "$dir/implementations/backlog" "$dir/implementations/stories"
  echo "$dir"
}

mk_backlog() {
  local fix="$1" id="$2" slug="$3" status="$4"
  local f="$fix/implementations/backlog/${id}-${slug}.md"
  printf '<!-- status: %s -->\n\n# %s backlog item\n' "$status" "$slug" > "$f"
  echo "$f"
}

mk_story() {
  local fix="$1" id="$2" slug="$3" backlog_basename="$4"
  local f="$fix/implementations/stories/${id}-${slug}.md"
  printf '<!-- status: filed -->\n\n# %s story\n\nSource backlog: implementations/backlog/%s\n' "$slug" "$backlog_basename" > "$f"
  echo "$f"
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: clean state — backlog accepted, no matching story → 0 mismatches.
DIR=$(mk_fixture)
mk_backlog "$DIR" "001" "test-item-clean" "accepted" > /dev/null
COUNT=$(coherence_check "$DIR")
assert_eq "case-1-clean-no-mismatches" "0" "$COUNT"
rm -rf "$DIR"

# Case 2: backlog accepted + matching story filed → 1 mismatch.
DIR=$(mk_fixture)
mk_backlog "$DIR" "002" "test-item-mismatch" "accepted" > /dev/null
mk_story "$DIR" "100" "test-story" "002-test-item-mismatch.md" > /dev/null
COUNT=$(coherence_check "$DIR")
assert_eq "case-2-single-mismatch-detected" "1" "$COUNT"
rm -rf "$DIR"

# Case 3: auto-promote flips status + appends pointer.
DIR=$(mk_fixture)
mk_backlog "$DIR" "003" "test-promote" "accepted" > /dev/null
mk_story "$DIR" "100" "test-story-3" "003-test-promote.md" > /dev/null
( cd "$DIR" && bash "$HELPER" --promote-only "003" "100" "test-story-3" "test-sprint" >/dev/null )
NEW_STATUS=$(head -1 "$DIR/implementations/backlog/003-test-promote.md" | grep -oE 'status: [a-z-]+' | awk '{print $2}')
assert_eq "case-3-status-flipped" "promoted" "$NEW_STATUS"
HAS_POINTER=$(grep -c 'promoted-to: implementations/stories/100-test-story-3.md' "$DIR/implementations/backlog/003-test-promote.md")
assert_eq "case-3-pointer-appended" "1" "$HAS_POINTER"
HAS_SPRINT_TAG=$(grep -c '(sprint test-sprint)' "$DIR/implementations/backlog/003-test-promote.md")
assert_eq "case-3-sprint-tag-included" "1" "$HAS_SPRINT_TAG"
rm -rf "$DIR"

# Case 4: helper refuses on already-promoted backlog (exit 3).
DIR=$(mk_fixture)
mk_backlog "$DIR" "004" "already-promoted" "promoted" > /dev/null
( cd "$DIR" && bash "$HELPER" --promote-only "004" "100" "test" 2>/dev/null )
RC=$?
assert_eq "case-4-refuse-on-promoted-rc" "3" "$RC"
rm -rf "$DIR"

# Case 5: helper refuses on rejected backlog (exit 3).
DIR=$(mk_fixture)
mk_backlog "$DIR" "005" "already-rejected" "rejected" > /dev/null
( cd "$DIR" && bash "$HELPER" --promote-only "005" "100" "test" 2>/dev/null )
RC=$?
assert_eq "case-5-refuse-on-rejected-rc" "3" "$RC"
rm -rf "$DIR"

# Case 6: target story already exists → exit 4.
DIR=$(mk_fixture)
mk_backlog "$DIR" "006" "test-target" "accepted" > /dev/null
mk_story "$DIR" "200" "test-existing" "006-test-target.md" > /dev/null
echo "story body" | ( cd "$DIR" && bash "$HELPER" "006" "200" "test-existing" 2>/dev/null )
RC=$?
assert_eq "case-6-refuse-on-existing-story-rc" "4" "$RC"
rm -rf "$DIR"

# Case 7: full helper invocation creates story + promotes backlog.
DIR=$(mk_fixture)
mk_backlog "$DIR" "007" "test-full" "accepted" > /dev/null
echo "<!-- status: filed -->\n\n# new story body\n" | ( cd "$DIR" && bash "$HELPER" "007" "300" "test-new-story" >/dev/null )
[ -f "$DIR/implementations/stories/300-test-new-story.md" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-7-story-created"); }
NEW_STATUS=$(head -1 "$DIR/implementations/backlog/007-test-full.md" | grep -oE 'status: [a-z-]+' | awk '{print $2}')
assert_eq "case-7-backlog-promoted" "promoted" "$NEW_STATUS"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "backlog-promotion-coherence: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
