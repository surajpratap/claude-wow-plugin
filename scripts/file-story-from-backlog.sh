#!/usr/bin/env bash
# file-story-from-backlog.sh — atomic backlog-promotion + story-creation helper.
#
# Args: <backlog-id> <story-id> <story-slug> [sprint-id]
# Stdin (or --story-body-file <path>): the story body to write.
#
# Refuses with non-zero exit if:
#   - backlog file not found (exit 2)
#   - backlog file is not currently `<!-- status: accepted -->` (exit 3)
#   - target story file already exists (exit 4)
#
# Side-effects:
#   - Creates implementations/stories/<story-id>-<story-slug>.md from stdin/file
#   - Edits implementations/backlog/<backlog-id>-*.md: flips accepted → promoted
#   - Appends `<!-- promoted-to: implementations/stories/<story-id>-<story-slug>.md [(sprint <sprint-id>)] -->`
#   - Stages both files via `git add` (no commit — caller decides)
#
# Promote-only mode: --promote-only flag skips story-file creation; just flips
# the backlog status + appends the pointer. Used by M's startup coherence-repair
# path when story already exists.

set -u

PROMOTE_ONLY=0
STORY_BODY_FILE=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --promote-only) PROMOTE_ONLY=1; shift ;;
    --story-body-file) STORY_BODY_FILE="$2"; shift 2 ;;
    -h|--help)
      head -22 "$0" | tail -21
      exit 0
      ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ "${#ARGS[@]}" -lt 3 ]; then
  echo "usage: $0 <backlog-id> <story-id> <story-slug> [sprint-id] [--promote-only] [--story-body-file <path>]" >&2
  exit 2
fi

BACKLOG_ID="${ARGS[0]}"
STORY_ID="${ARGS[1]}"
STORY_SLUG="${ARGS[2]}"
SPRINT_ID="${ARGS[3]:-}"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BACKLOG_FILE=$(ls "$ROOT/implementations/backlog/${BACKLOG_ID}-"*.md 2>/dev/null | head -1)
if [ -z "$BACKLOG_FILE" ] || [ ! -f "$BACKLOG_FILE" ]; then
  echo "no backlog file matching $BACKLOG_ID" >&2
  exit 2
fi

CURRENT_STATUS=$(head -1 "$BACKLOG_FILE" | grep -oE 'status: [a-z-]+' | awk '{print $2}')
if [ "$CURRENT_STATUS" != "accepted" ]; then
  echo "backlog $BACKLOG_ID: status is '$CURRENT_STATUS', expected 'accepted'" >&2
  exit 3
fi

STORY_FILE="$ROOT/implementations/stories/${STORY_ID}-${STORY_SLUG}.md"

if [ "$PROMOTE_ONLY" -eq 0 ]; then
  if [ -e "$STORY_FILE" ]; then
    echo "story file already exists: $STORY_FILE" >&2
    exit 4
  fi
  if [ -n "$STORY_BODY_FILE" ]; then
    if [ ! -f "$STORY_BODY_FILE" ]; then
      echo "story body file not found: $STORY_BODY_FILE" >&2
      exit 2
    fi
    cp "$STORY_BODY_FILE" "$STORY_FILE"
  else
    cat > "$STORY_FILE"
  fi
fi

sed -i.bak 's|<!-- status: accepted -->|<!-- status: promoted -->|' "$BACKLOG_FILE"
rm -f "$BACKLOG_FILE.bak"

POINTER="<!-- promoted-to: implementations/stories/${STORY_ID}-${STORY_SLUG}.md"
if [ -n "$SPRINT_ID" ]; then
  POINTER="${POINTER} (sprint ${SPRINT_ID})"
fi
POINTER="${POINTER} -->"
printf '\n%s\n' "$POINTER" >> "$BACKLOG_FILE"

git add "$BACKLOG_FILE" 2>/dev/null || true
if [ "$PROMOTE_ONLY" -eq 0 ]; then
  git add "$STORY_FILE" 2>/dev/null || true
fi

printf 'promoted backlog %s → story %s-%s\n' "$BACKLOG_ID" "$STORY_ID" "$STORY_SLUG"
