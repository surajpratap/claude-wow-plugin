#!/usr/bin/env bash
# m-prior-merge-detect.sh — Story 064.
#
# Detect whether a candidate story has already been shipped to main.
# Read by M's release-scan (Phase 1 + cron-tick proactive-release) before
# emitting `story-created` to SD, to prevent re-releasing already-shipped
# stories whose status line was never flipped from `filed` to `done`
# (real incident 2026-05-07: Story 053 / PR #50).
#
# Usage:
#   bash scripts/m-prior-merge-detect.sh <story-id> <story-slug> [<repo-root>]
#
# Output (one line on stdout, exit 0):
#   MATCH      <pr-number> <merge-sha> <merge-subject>
#   AMBIGUOUS  <pr-number> <merge-sha> <merge-subject>
#   NONE
#
# Exit 1 only on internal errors (git not available, story-id empty, etc.).
#
# Two-tier match (per Story 064 plan):
#   Tier 1 — explicit story-id reference in merge subject → MATCH:
#     - feat\(0*<NNN>\)
#     - story 0*<NNN>   (case-insensitive)
#     - 0*<NNN>:        (e.g. "053: <subject>")
#   Tier 2 — feat-branch was merged but subject didn't reference story-id
#     → AMBIGUOUS:
#     - merge subject contains (#<digits>); gh pr view <pr> shows
#       headRefName matches feat/0*<NNN>-
#
# Tier 2 requires `gh` on PATH + auth. If gh is missing or fails, Tier 2
# is skipped and the helper falls back to "Tier 1 only" — preferring
# conservative NONE over noisy AMBIGUOUS. Stderr logs the fallback.

set -u

STORY_ID="${1:?usage: <story-id> <story-slug> [<repo-root>]}"
STORY_SLUG="${2:?usage: <story-id> <story-slug> [<repo-root>]}"
REPO_ROOT="${3:-$(git rev-parse --show-toplevel 2>/dev/null)}"

if [ -z "$REPO_ROOT" ] || [ ! -e "$REPO_ROOT/.git" ]; then
  echo "m-prior-merge-detect: not in a git repo (REPO_ROOT=$REPO_ROOT)" >&2
  exit 1
fi

# Strip leading zeros for the unpadded match form, but ALSO match the
# zero-padded form. STORY_ID may come as "053" or "53"; both must match.
NNN_PADDED="$STORY_ID"  # as-given
NNN_UNPADDED="$(printf '%d' "$((10#$STORY_ID))" 2>/dev/null || echo "$STORY_ID")"

# Tier 1: scan main's commit history for explicit story-id references.
# Use --format=%H|%s so we can split on a stable delimiter.
TIER1_MATCH=""
while IFS='|' read -r SHA SUBJECT; do
  [ -z "$SHA" ] && continue
  # Pattern A: feat(NNN) / feat(0NN) / feat(0...0NNN) — handle padded/unpadded.
  if printf '%s' "$SUBJECT" | grep -qE "feat\(0*${NNN_UNPADDED}\)"; then
    TIER1_MATCH="$SHA|$SUBJECT"
    break
  fi
  # Pattern B: "story NNN" / "Story NNN" (case-insensitive).
  if printf '%s' "$SUBJECT" | grep -qiE "story 0*${NNN_UNPADDED}\b"; then
    TIER1_MATCH="$SHA|$SUBJECT"
    break
  fi
  # Pattern C: leading "NNN: <subject>" (with optional zero-padding).
  if printf '%s' "$SUBJECT" | grep -qE "^0*${NNN_UNPADDED}:"; then
    TIER1_MATCH="$SHA|$SUBJECT"
    break
  fi
done < <(git -C "$REPO_ROOT" log --format='%H|%s' main 2>/dev/null || git -C "$REPO_ROOT" log --format='%H|%s' 2>/dev/null)

if [ -n "$TIER1_MATCH" ]; then
  SHA="${TIER1_MATCH%%|*}"
  SUBJECT="${TIER1_MATCH#*|}"
  PR_NUM="$(printf '%s' "$SUBJECT" | grep -oE '#[0-9]+' | head -1 | tr -d '#')"
  PR_NUM="${PR_NUM:-?}"
  printf 'MATCH %s %s %s\n' "$PR_NUM" "$SHA" "$SUBJECT"
  exit 0
fi

# Tier 2: scan for "(#<digits>)" merge subjects, then check each PR's
# headRefName for feat/0*<NNN>-<...>. Skip if `gh` is not available.
if ! command -v gh >/dev/null 2>&1; then
  echo "m-prior-merge-detect: gh not on PATH; skipping Tier-2 (AMBIGUOUS) check" >&2
  echo "NONE"
  exit 0
fi

# Capture all (#<digits>)-tagged merges; for each, check headRefName.
TIER2_MATCH=""
while IFS='|' read -r SHA SUBJECT; do
  [ -z "$SHA" ] && continue
  PR_NUM="$(printf '%s' "$SUBJECT" | grep -oE '#[0-9]+' | head -1 | tr -d '#')"
  [ -z "$PR_NUM" ] && continue
  # Query PR head ref. `gh` failures (no auth, network, missing PR) are
  # non-fatal — fall through to next candidate.
  HEAD_REF="$(gh pr view "$PR_NUM" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
  [ -z "$HEAD_REF" ] && continue
  # Match feat/<NNN>-* or feat/0*<NNN>-* (zero-padding tolerated).
  if printf '%s' "$HEAD_REF" | grep -qE "^feat/0*${NNN_UNPADDED}-"; then
    TIER2_MATCH="$PR_NUM|$SHA|$SUBJECT"
    break
  fi
done < <(git -C "$REPO_ROOT" log --format='%H|%s' main 2>/dev/null || git -C "$REPO_ROOT" log --format='%H|%s' 2>/dev/null)

if [ -n "$TIER2_MATCH" ]; then
  PR_NUM="${TIER2_MATCH%%|*}"
  REST="${TIER2_MATCH#*|}"
  SHA="${REST%%|*}"
  SUBJECT="${REST#*|}"
  printf 'AMBIGUOUS %s %s %s\n' "$PR_NUM" "$SHA" "$SUBJECT"
  exit 0
fi

echo "NONE"
exit 0
