#!/usr/bin/env bash
# Story 100 — story-current.sh prints the canonical-branch story (not the
# worktree's possibly-stale copy); the story-revised re-read doctrine is wired
# into SD / PP / M / the protocol spec.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

assert_grep() {
  local name="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (pattern '$pattern' not in $file)")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$ROOT/scripts/story-current.sh"
CMD="$ROOT/commands"

if [ ! -f "$HELPER" ]; then
  echo "story-current-canonical-read: SKIP — $HELPER not found"
  exit 0
fi

# --- fixture: a bare `origin` + a clone with story 100-x committed to main.
WORK=$(mktemp -d)
ORIGIN="$WORK/origin.git"
CLONE="$WORK/clone"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
(
  cd "$CLONE" || exit 1
  git config user.email t@example.com; git config user.name tester
  git checkout -q -b main
  mkdir -p implementations/stories
  printf 'CANONICAL v1\n' > implementations/stories/100-x.md
  git add -A && git commit -q -m "story 100 v1"
  git push -q -u origin main 2>/dev/null
  git remote set-head origin main 2>/dev/null
)

# Case a — an uncommitted worktree edit is ignored; helper prints committed text.
printf 'STALE WORKTREE EDIT\n' > "$CLONE/implementations/stories/100-x.md"
OUT_A=$(cd "$CLONE" && bash "$HELPER" 100 2>/dev/null)
assert_eq "a-canonical-over-worktree-edit" "CANONICAL v1" "$OUT_A"

# Case b — a pushed remote advance is picked up by the helper's git fetch.
CLONE2="$WORK/clone2"
git clone -q "$ORIGIN" "$CLONE2" 2>/dev/null
(
  cd "$CLONE2" || exit 1
  git config user.email t@example.com; git config user.name tester
  git checkout -q main
  printf 'CANONICAL v2 REVISED\n' > implementations/stories/100-x.md
  git add -A && git commit -q -m "story 100 v2"
  git push -q origin main 2>/dev/null
)
OUT_B=$(cd "$CLONE" && bash "$HELPER" 100 2>/dev/null)
assert_eq "b-remote-advance-fetched" "CANONICAL v2 REVISED" "$OUT_B"

# Case c — no story matches → exit 2.
( cd "$CLONE" && bash "$HELPER" 999 >/dev/null 2>&1 )
assert_eq "c-no-match-exit-2" "2" "$?"

# Case d — numeric id and full slug resolve the same file.
OUT_D1=$(cd "$CLONE" && bash "$HELPER" 100 2>/dev/null)
OUT_D2=$(cd "$CLONE" && bash "$HELPER" 100-x 2>/dev/null)
assert_eq "d-slug-or-numeric-id" "$OUT_D1" "$OUT_D2"

rm -rf "$WORK"

# Case e — doctrine wiring: the story-revised re-read path is present in all
# four files the plan touches.
assert_grep "e-sd-story-revised-handler"  'story-revised.*story-current\.sh|story-current\.sh.*story-revised' "$CMD/senior-developer.md"
assert_grep "e-pp-story-revised-handler"  'story-revised.*story-current\.sh|story-current\.sh.*story-revised' "$CMD/pair-programmer.md"
assert_grep "e-manager-emits-story-revised" 'story-revised' "$CMD/manager.md"
assert_grep "e-protocol-row"              '\| `story-revised`' "$CMD/_agent-protocol.md"

# Story 107 — PP's story-done handler ALSO needs the canonical-read pointer
# (FINDING-25 closure; the plan-ready-for-review pointer is the model).
assert_grep "e-pp-story-done-handler"     'story-done.*story-current\.sh|story-current\.sh.*story-done' "$CMD/pair-programmer.md"

echo "story-current-canonical-read: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
