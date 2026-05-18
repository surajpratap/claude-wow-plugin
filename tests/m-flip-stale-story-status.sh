#!/usr/bin/env bash
# Story 123 — m-flip-stale-story-status.sh post-merge line-1 normalizer.
#
# Cases:
#   1. Stale `in-progress` line 1 → script flips to `done` + commits.
#   2. Already-`done` line 1 → silent noop, no commit added.
#   3a. Stale `backlog` line 1 → flipped to `done`.
#   3b. Stale `in-review` line 1 (multi-token coverage) → flipped to `done`.
#   4. Bad-shape line 1 (no status marker) → exit 2, no commit.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/m-flip-stale-story-status.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: missing $SCRIPT" >&2
  exit 2
fi

# Build a fresh fixture: tmp git repo + stories/<NNN>-<slug>.md with given line 1.
mk_fixture() {
  local line1="$1"
  local D
  D=$(mktemp -d)
  (
    cd "$D" || exit 99
    git init --quiet
    git config user.email "t@t.t"
    git config user.name "t"
    git config commit.gpgsign false
    mkdir -p implementations/stories
    printf '%s\n\n# Story 999 — fixture body\n' "$line1" > implementations/stories/999-fixture.md
    git add implementations/stories/999-fixture.md
    git commit -m "seed" --quiet
  )
  echo "$D"
}

count_commits() {
  local D="$1"
  ( cd "$D" || exit 99; git rev-list --count HEAD )
}

read_line1() {
  local D="$1"
  head -n 1 "$D/implementations/stories/999-fixture.md"
}

# Case 1: in-progress → flipped + committed.
D1=$(mk_fixture "<!-- status: in-progress -->")
PRE_COMMITS_1=$(count_commits "$D1")
( cd "$D1" || exit 99; bash "$SCRIPT" implementations/stories/999-fixture.md >/dev/null 2>&1; echo $? > /tmp/m-flip-test-rc1.$$ )
RC1=$(cat /tmp/m-flip-test-rc1.$$); rm -f /tmp/m-flip-test-rc1.$$
POST_COMMITS_1=$(count_commits "$D1")
POST_LINE1_1=$(read_line1 "$D1")
DELTA_1=$((POST_COMMITS_1 - PRE_COMMITS_1))
assert_eq "1-in-progress-rc"           "0"                          "$RC1"
assert_eq "1-in-progress-line1-flipped" "<!-- status: done -->"     "$POST_LINE1_1"
assert_eq "1-in-progress-1-new-commit" "1"                          "$DELTA_1"
rm -rf "$D1"

# Case 2: already-done → silent noop, no commit added.
D2=$(mk_fixture "<!-- status: done -->")
PRE_COMMITS_2=$(count_commits "$D2")
( cd "$D2" || exit 99; bash "$SCRIPT" implementations/stories/999-fixture.md >/dev/null 2>&1; echo $? > /tmp/m-flip-test-rc2.$$ )
RC2=$(cat /tmp/m-flip-test-rc2.$$); rm -f /tmp/m-flip-test-rc2.$$
POST_COMMITS_2=$(count_commits "$D2")
POST_LINE1_2=$(read_line1 "$D2")
DELTA_2=$((POST_COMMITS_2 - PRE_COMMITS_2))
assert_eq "2-already-done-rc"               "0"                          "$RC2"
assert_eq "2-already-done-line1-unchanged"  "<!-- status: done -->"     "$POST_LINE1_2"
assert_eq "2-already-done-no-new-commit"    "0"                          "$DELTA_2"
rm -rf "$D2"

# Case 3a: backlog → flipped.
D3a=$(mk_fixture "<!-- status: backlog -->")
( cd "$D3a" || exit 99; bash "$SCRIPT" implementations/stories/999-fixture.md >/dev/null 2>&1; echo $? > /tmp/m-flip-test-rc3a.$$ )
RC3A=$(cat /tmp/m-flip-test-rc3a.$$); rm -f /tmp/m-flip-test-rc3a.$$
POST_LINE1_3A=$(read_line1 "$D3a")
assert_eq "3a-backlog-rc"             "0"                          "$RC3A"
assert_eq "3a-backlog-line1-flipped"  "<!-- status: done -->"     "$POST_LINE1_3A"
rm -rf "$D3a"

# Case 3b: in-review (multi-token coverage — guards round-1 sed regex bug).
D3b=$(mk_fixture "<!-- status: in-review -->")
( cd "$D3b" || exit 99; bash "$SCRIPT" implementations/stories/999-fixture.md >/dev/null 2>&1; echo $? > /tmp/m-flip-test-rc3b.$$ )
RC3B=$(cat /tmp/m-flip-test-rc3b.$$); rm -f /tmp/m-flip-test-rc3b.$$
POST_LINE1_3B=$(read_line1 "$D3b")
assert_eq "3b-in-review-rc"           "0"                          "$RC3B"
assert_eq "3b-in-review-line1-flipped" "<!-- status: done -->"    "$POST_LINE1_3B"
rm -rf "$D3b"

# Case 4: bad-shape line 1 → exit 2, no commit.
D4=$(mk_fixture "# Not a status marker")
PRE_COMMITS_4=$(count_commits "$D4")
( cd "$D4" || exit 99; bash "$SCRIPT" implementations/stories/999-fixture.md >/dev/null 2>&1; echo $? > /tmp/m-flip-test-rc4.$$ )
RC4=$(cat /tmp/m-flip-test-rc4.$$); rm -f /tmp/m-flip-test-rc4.$$
POST_COMMITS_4=$(count_commits "$D4")
DELTA_4=$((POST_COMMITS_4 - PRE_COMMITS_4))
assert_eq "4-bad-shape-rc-2"           "2"                          "$RC4"
assert_eq "4-bad-shape-no-new-commit"  "0"                          "$DELTA_4"
rm -rf "$D4"

echo "m-flip-stale-story-status: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
