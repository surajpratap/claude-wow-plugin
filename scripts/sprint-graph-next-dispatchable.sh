#!/usr/bin/env bash
# Story 012 / Section C — sprint dispatch graph helper.
#
# Usage: scripts/sprint-graph-next-dispatchable.sh <manifest-path>
# Prints (one per line) the item ids that are dispatchable RIGHT NOW.
# An item is dispatchable iff:
#   - its status is "pending"
#   - every item in its depends_on[] has status "merged" OR "shipped"
#     OR (for stacked items) status "dispatched" / "in-review" / "merged" / "shipped"
#
# Dispatchable list is bounded by manifest.concurrency_limit minus the
# count of currently-in-flight items (status in dispatched / in-review /
# spike-running). Printed list is at most that bound, in manifest order.
#
# Exit 0 always; empty output if nothing dispatchable.

set -u

MANIFEST="${1:-}"
if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
  echo "usage: $0 <manifest-path>" >&2
  exit 2
fi

CL=$(jq -r '.concurrency_limit // 3' "$MANIFEST")

# Count in-flight items.
INFLIGHT=$(jq -r '[.items[] | select(.status == "dispatched" or .status == "in-review" or .status == "spike-running")] | length' "$MANIFEST")
SLOTS=$((CL - INFLIGHT))
if [ "$SLOTS" -le 0 ]; then
  exit 0
fi

# For each pending item, check if all depends_on are satisfied.
N=$(jq '.items | length' "$MANIFEST")
i=0
PRINTED=0
while [ "$i" -lt "$N" ] && [ "$PRINTED" -lt "$SLOTS" ]; do
  ITEM=$(jq ".items[$i]" "$MANIFEST")
  IID=$(printf '%s' "$ITEM" | jq -r '.id')
  ISTATUS=$(printf '%s' "$ITEM" | jq -r '.status')
  if [ "$ISTATUS" != "pending" ]; then
    i=$((i + 1))
    continue
  fi

  # Check each dep
  DEP_COUNT=$(printf '%s' "$ITEM" | jq '.depends_on // [] | length')
  STACKED_ON=$(printf '%s' "$ITEM" | jq -r '.stacked_on // ""')
  ok=1
  j=0
  while [ "$j" -lt "$DEP_COUNT" ]; do
    DEP=$(printf '%s' "$ITEM" | jq -r ".depends_on[$j]")
    DEP_STATUS=$(jq -r --arg d "$DEP" '.items[] | select(.id == $d) | .status // empty' "$MANIFEST")
    if [ -n "$STACKED_ON" ]; then
      case "$DEP_STATUS" in
        dispatched|in-review|merged|shipped) ;;
        *) ok=0 ;;
      esac
    else
      case "$DEP_STATUS" in
        merged|shipped) ;;
        *) ok=0 ;;
      esac
    fi
    [ "$ok" -eq 0 ] && break
    j=$((j + 1))
  done

  # Stacked-child plan-approved gate (introduced in v2.19.0).
  # Stacked children become dispatchable only when their parent's plan
  # has been approved (not just when the parent has been dispatched).
  # This defers branch+worktree creation until the parent's branch has
  # commits (eliminating the version-literal cascade-conflict class).
  # Gate is keyed off STACKED_ON (the parent feat-branch); if the
  # parent's item id can't be determined, gate fails closed.
  if [ "$ok" -eq 1 ] && [ -n "$STACKED_ON" ]; then
    PARENT_ID=$(jq -r --arg b "$STACKED_ON" '.items[] | select(.branch == $b) | .id // empty' "$MANIFEST" | head -1)
    if [ -z "$PARENT_ID" ]; then
      ok=0
    else
      PARENT_PLAN_APPROVED=$(jq -r --arg id "$PARENT_ID" '.items[] | select(.id == $id) | .plan_approved_at // empty' "$MANIFEST")
      if [ -z "$PARENT_PLAN_APPROVED" ] || [ "$PARENT_PLAN_APPROVED" = "null" ]; then
        ok=0
      fi
    fi
  fi

  if [ "$ok" -eq 1 ]; then
    printf '%s\n' "$IID"
    PRINTED=$((PRINTED + 1))
  fi

  i=$((i + 1))
done
