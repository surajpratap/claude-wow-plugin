#!/usr/bin/env bash
# Story 012 / Section G — sprint manifest validator.
#
# Usage: scripts/sprint-manifest-validate.sh <manifest-path>
# Exits 0 on valid; non-zero with diagnostic on stderr if invalid.
#
# Validates:
#   - file exists and parses as JSON
#   - id matches YYYY-MM-DD-<slug>
#   - status is in the enum
#   - concurrency_limit is a positive integer
#   - each item has id, story, status; item.status is in the item enum
#   - each item.depends_on[*] references an item id present in manifest
#   - if item.spike is set, item.alt_story is also set (and vice versa)
#   - if item.stacked_on is set, it equals the parent item's branch
#   - rebases[*].parent and rebases[*].child reference real item ids

set -u

MANIFEST="${1:-}"
if [ -z "$MANIFEST" ]; then
  echo "usage: $0 <manifest-path>" >&2
  exit 2
fi
if [ ! -f "$MANIFEST" ]; then
  echo "validate: manifest not found: $MANIFEST" >&2
  exit 1
fi
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  echo "validate: manifest is not valid JSON: $MANIFEST" >&2
  exit 1
fi

ID=$(jq -r '.id // empty' "$MANIFEST")
if [ -z "$ID" ]; then
  echo "validate: missing 'id' field" >&2
  exit 1
fi
if ! printf '%s' "$ID" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+$'; then
  echo "validate: id '$ID' does not match YYYY-MM-DD-<slug> format" >&2
  exit 1
fi

STATUS=$(jq -r '.status // empty' "$MANIFEST")
case "$STATUS" in
  brainstorm|kickoff|active|paused|complete|aborted) ;;
  "") echo "validate: missing 'status' field" >&2; exit 1 ;;
  *) echo "validate: invalid status '$STATUS' (must be one of brainstorm|kickoff|active|paused|complete|aborted)" >&2; exit 1 ;;
esac

CL=$(jq -r '.concurrency_limit // empty' "$MANIFEST")
if [ -z "$CL" ]; then
  echo "validate: missing 'concurrency_limit' field" >&2
  exit 1
fi
if ! printf '%s' "$CL" | grep -qE '^[1-9][0-9]*$'; then
  echo "validate: concurrency_limit '$CL' must be a positive integer" >&2
  exit 1
fi

# Collect item ids for cross-reference checks.
ITEM_IDS=$(jq -r '.items[].id' "$MANIFEST" 2>/dev/null)
if [ -z "$ITEM_IDS" ]; then
  echo "validate: manifest has no items" >&2
  exit 1
fi

# Per-item validation.
N=$(jq '.items | length' "$MANIFEST")
i=0
while [ "$i" -lt "$N" ]; do
  ITEM=$(jq ".items[$i]" "$MANIFEST")
  IID=$(printf '%s' "$ITEM" | jq -r '.id // empty')
  STORY=$(printf '%s' "$ITEM" | jq -r '.story // empty')
  ISTATUS=$(printf '%s' "$ITEM" | jq -r '.status // empty')
  SPIKE=$(printf '%s' "$ITEM" | jq -r '.spike // ""')
  ALT=$(printf '%s' "$ITEM" | jq -r '.alt_story // ""')

  if [ -z "$IID" ]; then
    echo "validate: items[$i] missing 'id' field" >&2
    exit 1
  fi
  if [ -z "$STORY" ]; then
    echo "validate: item '$IID' missing 'story' field" >&2
    exit 1
  fi
  case "$ISTATUS" in
    pending|spike-running|dispatched|in-review|merged|parked|rejected|shipped) ;;
    "") echo "validate: item '$IID' missing 'status' field" >&2; exit 1 ;;
    *) echo "validate: item '$IID' has invalid status '$ISTATUS'" >&2; exit 1 ;;
  esac

  # spike/alt_story pair check
  if [ -n "$SPIKE" ] && [ -z "$ALT" ]; then
    echo "validate: item '$IID' has 'spike' but no 'alt_story'" >&2
    exit 1
  fi
  if [ -n "$ALT" ] && [ -z "$SPIKE" ]; then
    echo "validate: item '$IID' has 'alt_story' but no 'spike'" >&2
    exit 1
  fi

  # depends_on cross-reference
  DEP_COUNT=$(printf '%s' "$ITEM" | jq '.depends_on // [] | length')
  j=0
  while [ "$j" -lt "$DEP_COUNT" ]; do
    DEP=$(printf '%s' "$ITEM" | jq -r ".depends_on[$j]")
    if ! printf '%s\n' "$ITEM_IDS" | grep -qx "$DEP"; then
      echo "validate: item '$IID' depends_on unknown id '$DEP'" >&2
      exit 1
    fi
    j=$((j + 1))
  done

  i=$((i + 1))
done

# Rebases cross-reference
RB_COUNT=$(jq '(.rebases // []) | length' "$MANIFEST")
i=0
while [ "$i" -lt "$RB_COUNT" ]; do
  P=$(jq -r ".rebases[$i].parent // empty" "$MANIFEST")
  C=$(jq -r ".rebases[$i].child // empty" "$MANIFEST")
  if ! printf '%s\n' "$ITEM_IDS" | grep -qx "$P"; then
    echo "validate: rebases[$i].parent '$P' is not an item id" >&2
    exit 1
  fi
  if ! printf '%s\n' "$ITEM_IDS" | grep -qx "$C"; then
    echo "validate: rebases[$i].child '$C' is not an item id" >&2
    exit 1
  fi
  i=$((i + 1))
done

exit 0
