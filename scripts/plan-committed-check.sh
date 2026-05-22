#!/usr/bin/env bash
# Story 140: guard SD runs before plan-done — verifies the plan file is committed
# on the FEAT branch (not orphaned untracked on main, the 135/137/138/139 bug).
#
#   plan-committed-check.sh <plan-file>
#
# exit 0 iff the plan is git-tracked AND has no uncommitted diff vs HEAD AND the
#   current branch matches feat/* ;
# exit 1 untracked / uncommitted / wrong-branch (incl. main, detached HEAD) ;
# exit 2 usage / missing file.
set -u

plan="${1:-}"
[ -n "$plan" ] || { echo "usage: plan-committed-check.sh <plan-file>" >&2; exit 2; }
[ -f "$plan" ] || { echo "plan-committed-check: file not found — $plan" >&2; exit 2; }

dir=$(cd "$(dirname "$plan")" && pwd)
base=$(basename "$plan")

branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$branch" in
  feat/*) ;;
  *) echo "plan-committed-check: plan not on a feat/* branch (on '${branch:-detached}') — $plan" >&2; exit 1 ;;
esac

if ! git -C "$dir" ls-files --error-unmatch "$base" >/dev/null 2>&1; then
  echo "plan-committed-check: untracked on the feat branch — $plan" >&2; exit 1
fi
if ! git -C "$dir" diff --quiet HEAD -- "$base" 2>/dev/null; then
  echo "plan-committed-check: uncommitted changes vs HEAD — $plan" >&2; exit 1
fi
exit 0
