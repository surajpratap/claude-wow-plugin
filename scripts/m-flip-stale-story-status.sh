#!/usr/bin/env bash
# Story 123 — idempotent post-merge story-status line-1 normalizer.
#
# Reads line 1 of <story-path>. If it's already `<!-- status: done -->`,
# exits 0 silent. Otherwise rewrites line 1 to `<!-- status: done -->` +
# git-commits the change as a standing-authority workflow-artifact tweak.
#
# Invoked by M's pr-state:merged handler — catches the class of bug where
# a stacked-merge sequence lands a story-done trailer commit but misses
# the line-1 status flip (sprint 2026-05-13 surfaced story 072 this way).
#
# Exit codes:
#   0 — line 1 already `done`, OR line 1 flipped + commit landed.
#   2 — bad-shape input: path unreadable, OR line 1 not a recognizable
#       `<!-- status: <token> -->` marker (defensive guard against
#       accidental run on a non-story path).

set -u

STORY="${1:-}"
if [ -z "$STORY" ] || [ ! -f "$STORY" ]; then
  echo "m-flip-stale-story-status: missing/unreadable story path: $STORY" >&2
  exit 2
fi

LINE1=$(head -n 1 "$STORY")
case "$LINE1" in
  '<!-- status: done -->')
    exit 0
    ;;
  '<!-- status: '*' -->')
    : # fall through to flip
    ;;
  *)
    echo "m-flip-stale-story-status: line 1 is not a status marker: $LINE1" >&2
    exit 2
    ;;
esac

# Story 123 — BSD/GNU sed compatible BRE pattern. Original `[^-]*` form
# silently skipped multi-token statuses (in-progress, in-review, wont-fix)
# because the dash terminates the negated character class. [a-z-]\{1,\}
# matches lowercase + dashes, so all multi-token statuses match.
sed -i.bak '1s|^<!-- status: [a-z-]\{1,\} -->$|<!-- status: done -->|' "$STORY"
rm -f "${STORY}.bak"

NEW_LINE1=$(head -n 1 "$STORY")
if [ "$NEW_LINE1" != '<!-- status: done -->' ]; then
  echo "m-flip-stale-story-status: sed substitution failed (line 1 still: $NEW_LINE1)" >&2
  exit 2
fi

NNN=$(basename "$STORY" | sed 's|^\([0-9][0-9]*\)-.*\.md$|\1|')
git add "$STORY"
git commit -m "chore: post-merge flip story ${NNN} status to done

Idempotent line-1 normalizer ran by M's pr-state:merged handler
(Story 123). Catches the stacked-merge sequence where a story-done
trailer commit lands but the post-pick line-1 flip is missed.

Co-Authored-By: Claude <noreply@anthropic.com>" >/dev/null

exit 0
