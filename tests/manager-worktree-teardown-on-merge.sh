#!/usr/bin/env bash
# Story 120 — M tears down the story worktree on `pr-state: merged`, NOT on
# `pr-created`. Pins three placements in plugin/commands/manager.md so a future
# refactor cannot silently revert the doctrine:
#   (a) pr-created handler does NOT contain `git worktree remove` (anti-revert).
#   (b) proactive-release table row for pr-created does NOT contain
#       `worktree teardown` (anti-revert).
#   (c) pr-state: merged handler DOES contain
#       `git worktree remove .worktrees/<NNN-slug>` (positive presence).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MGR="$REPO_ROOT/commands/manager.md"

PASS=0
FAIL=0
FAILED_CASES=()

if [ ! -f "$MGR" ]; then
  echo "FATAL: missing manager.md at $MGR" >&2
  exit 2
fi

# (a) pr-created handler must NOT contain `git worktree remove`.
# Extract the pr-created bullet line. The doctrine line starts with
# "- `pr-created` (from SD" and runs until the next "- `" bullet (exclusive).
# Portable BSD/GNU awk range — flag-based extraction so we can stop before the
# closing line without relying on GNU `head -n -1`.
PR_CREATED_BLOCK=$(awk '/^- `pr-created` \(from SD/{flag=1} flag && /^- `/ && !/^- `pr-created`/{flag=0} flag' "$MGR")
case "$PR_CREATED_BLOCK" in
  *"git worktree remove"*)
    FAIL=$((FAIL+1))
    FAILED_CASES+=("(a) pr-created handler still contains 'git worktree remove' — Story 120 revert")
    ;;
  *)
    PASS=$((PASS+1))
    ;;
esac

# (b) proactive-release table row for `pr-created` must NOT contain
# `worktree teardown`.
PR_CREATED_ROW=$(grep -F '| `pr-created` on bus from SD' "$MGR")
case "$PR_CREATED_ROW" in
  *"worktree teardown"*)
    FAIL=$((FAIL+1))
    FAILED_CASES+=("(b) proactive-release pr-created row still mentions 'worktree teardown' — Story 120 revert")
    ;;
  *)
    PASS=$((PASS+1))
    ;;
esac

# (c) pr-state: merged handler MUST contain
# `git worktree remove .worktrees/<NNN-slug>`.
MERGED_BLOCK=$(awk '/^- `merged`: print to human/{flag=1} flag && /^- `closed`/{flag=0} flag' "$MGR")
case "$MERGED_BLOCK" in
  *"git worktree remove .worktrees/<NNN-slug>"*)
    PASS=$((PASS+1))
    ;;
  *)
    FAIL=$((FAIL+1))
    FAILED_CASES+=("(c) pr-state:merged handler missing 'git worktree remove .worktrees/<NNN-slug>'")
    ;;
esac

echo "manager-worktree-teardown-on-merge: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
