#!/usr/bin/env bash
# Story 012 / Section D — sprint rebase cascade.
#
# Usage: scripts/sprint-rebase-cascade.sh \
#   <parent-branch> <child-branch> <child-pr-number> \
#   <child-worktree-path> <manifest-path> <old-parent-sha> [parent-id child-id]
#
# Performs the cascade after a parent feat-branch merges into main:
#   1. Pre-flight: child worktree clean? (else exit 2)
#   2. git rebase --onto main <old-parent-sha> <child-branch>     (else exit 3)
#   3. git push --force-with-lease origin <child-branch>          (else exit 4)
#   4. gh pr edit <child-pr-number> --base main                   (else exit 5)
#   5. Append rebase entry to manifest (atomic via tmp + rename)
#   6. Exit 0
#
# old-parent-sha is the parent branch's tip BEFORE the merge — captured
# by M's prompt via `git rev-parse <parent-branch>@{1}` (reflog) and
# passed in. Accepting it as an explicit arg makes the script callable
# from a synthetic test that doesn't have a meaningful reflog (PP nit
# on Story 012 plan).

set -u

PARENT_BRANCH="${1:-}"
CHILD_BRANCH="${2:-}"
CHILD_PR="${3:-}"
CHILD_WT="${4:-}"
MANIFEST="${5:-}"
OLD_PARENT="${6:-}"
PARENT_ID="${7:-}"
CHILD_ID="${8:-}"

if [ -z "$PARENT_BRANCH" ] || [ -z "$CHILD_BRANCH" ] || [ -z "$CHILD_PR" ] \
   || [ -z "$CHILD_WT" ] || [ -z "$MANIFEST" ] || [ -z "$OLD_PARENT" ]; then
  echo "usage: $0 <parent-branch> <child-branch> <child-pr> <child-worktree> <manifest> <old-parent-sha> [parent-id child-id]" >&2
  exit 2
fi

# Step 1: Pre-flight worktree clean
DIRTY=$(git -C "$CHILD_WT" status --porcelain 2>/dev/null)
if [ -n "$DIRTY" ]; then
  echo "rebase-blocked: $CHILD_BRANCH worktree at $CHILD_WT has uncommitted changes:" >&2
  printf '%s\n' "$DIRTY" >&2
  exit 2
fi

# Step 2: Rebase onto main (run inside the child worktree so the rebase
# rewrites the right branch — `git -C` makes the cwd unambiguous).
if ! git -C "$CHILD_WT" rebase --onto main "$OLD_PARENT" "$CHILD_BRANCH" 2>/tmp/rebase-stderr.$$; then
  echo "rebase-conflict: $CHILD_BRANCH rebase --onto main $OLD_PARENT failed:" >&2
  cat /tmp/rebase-stderr.$$ >&2
  rm -f /tmp/rebase-stderr.$$
  # Best-effort abort to leave the working tree in a defined state.
  git -C "$CHILD_WT" rebase --abort 2>/dev/null || true
  exit 3
fi
rm -f /tmp/rebase-stderr.$$

# Step 3: Force-push with lease
if ! git -C "$CHILD_WT" push --force-with-lease origin "$CHILD_BRANCH" 2>/tmp/push-stderr.$$; then
  echo "rebase-stale: force-push for $CHILD_BRANCH rejected:" >&2
  cat /tmp/push-stderr.$$ >&2
  rm -f /tmp/push-stderr.$$
  exit 4
fi
rm -f /tmp/push-stderr.$$

# Step 4: Re-target PR base to main
if ! gh pr edit "$CHILD_PR" --base main 2>/tmp/gh-stderr.$$; then
  echo "rebase-pr-edit-failed: gh pr edit $CHILD_PR --base main failed:" >&2
  cat /tmp/gh-stderr.$$ >&2
  rm -f /tmp/gh-stderr.$$
  exit 5
fi
rm -f /tmp/gh-stderr.$$

# Step 5: Append rebase entry to manifest (atomic via tmp + rename)
NEW_SHA=$(git -C "$CHILD_WT" rev-parse "$CHILD_BRANCH")
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TMP="${MANIFEST}.tmp.$$"
jq --arg ts "$TS" \
   --arg parent "${PARENT_ID:-$PARENT_BRANCH}" \
   --arg child "${CHILD_ID:-$CHILD_BRANCH}" \
   --arg old_sha "$OLD_PARENT" \
   --arg new_sha "$NEW_SHA" \
   '.rebases = ((.rebases // []) + [{ts: $ts, parent: $parent, child: $child, old_sha: $old_sha, new_sha: $new_sha}])' \
   "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"

exit 0
