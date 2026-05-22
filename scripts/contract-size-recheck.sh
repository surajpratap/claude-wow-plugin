#!/usr/bin/env bash
# contract-size-recheck.sh — dispatch-time advisory size re-check (Story 142).
#
#   contract-size-recheck.sh <story-or-backlog-file>
#
# Flags a backlog/story as NOT-tiny when its text touches >1 role file OR a bus
# payload key/field OR an artifact location — these are migrations with
# cross-role review surface (stories 138/140 were mis-sized "tiny"). Advisory:
# M runs it at dispatch; a non-zero exit means "re-check sizing + name the
# contract owner (manifest `contract` field, story 102)" — NOT a hard block.
#
# Heuristic reads the STORY/BACKLOG TEXT only — a terse story can hide scope that
# only explodes in the PLAN (a plan-submit recheck is a noted follow-up). Biased
# toward flagging (advisory → a false positive costs M a glance; a false negative
# costs a parked story). POSIX ERE only (no `\b`; runs on stock BSD/macOS grep).
#
# Exit: 0 = looks tiny-ok, 1 = looks >=medium (reasons on stdout), 2 = usage/missing.

set -u

f="${1:-}"
[ -n "$f" ] || { echo "usage: contract-size-recheck.sh <story-or-backlog-file>" >&2; exit 2; }
[ -f "$f" ] || { echo "contract-size-recheck: file not found — $f" >&2; exit 2; }

reasons=()

# multi-role: >=2 distinct commands/<role>.md references
roles=$(grep -oE 'commands/[a-z0-9_-]+\.md' "$f" 2>/dev/null | LC_ALL=C sort -u | wc -l | tr -d ' ')
[ "${roles:-0}" -ge 2 ] && reasons+=("multi-role: touches $roles role files (cross-role migration surface)")

# payload-key: bus payload key/field language (loosened — catches "payload gains a … field")
if grep -Eiq 'payload.*(key|field)|(key|field).*payload' "$f" 2>/dev/null; then
  reasons+=("payload-key: changes a bus payload key/field (producer->consumer contract)")
fi

# artifact-location: move/relocate/orphan/where-X-lives/location-migration (POSIX word edges, no \b)
if grep -Eiq 'relocat|orphan|(^|[^a-z])moved?([^a-z]|$)|where .* (live|lives)|plan.*location|location.*migration' "$f" 2>/dev/null; then
  reasons+=("artifact-location: moves/relocates an artifact (multi-consumer migration)")
fi

if [ "${#reasons[@]}" -gt 0 ]; then
  for r in "${reasons[@]}"; do echo "  - $r"; done
  echo "size re-check: looks >=medium — re-check sizing + name the contract owner (manifest contract field, story 102)"
  exit 1
fi
exit 0
