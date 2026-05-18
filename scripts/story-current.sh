#!/usr/bin/env bash
# story-current.sh — print a story file from the canonical branch HEAD.
#
# Usage: story-current.sh <story-id>
#   <story-id> — numeric id ("100") or full slug ("100-worktree-stale-...").
#
# Inside a per-item worktree the checked-out story file is frozen at dispatch
# time; if M re-scoped the story afterward, that copy is stale. This helper
# prints the AUTHORITATIVE story from the canonical branch (origin/HEAD,
# default main) so SD/PP plan + review against current text. Exit 2 on no match.
set -u

ID="${1:?usage: story-current.sh <story-id>}"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

CANONICAL_BRANCH=$(git -C "$ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's|^refs/remotes/origin/||')
CANONICAL_BRANCH="${CANONICAL_BRANCH:-main}"

# Freshness is the helper's whole value — make a failed fetch VISIBLE.
# Non-fatal: offline still yields the last-fetched origin ref, just stale.
if ! git -C "$ROOT" fetch origin "$CANONICAL_BRANCH" --quiet 2>/dev/null; then
  echo "story-current: warning — could not fetch origin/${CANONICAL_BRANCH}; result may be stale" >&2
fi

num="${ID%%-*}"
match=$(git -C "$ROOT" ls-tree -r --name-only "origin/${CANONICAL_BRANCH}" \
          implementations/stories/ 2>/dev/null \
        | grep -E "^implementations/stories/${num}-" | head -n 1)

if [ -z "$match" ]; then
  echo "story-current: no story matching '${ID}' on origin/${CANONICAL_BRANCH}" >&2
  exit 2
fi

git -C "$ROOT" show "origin/${CANONICAL_BRANCH}:${match}"
