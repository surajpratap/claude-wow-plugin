#!/usr/bin/env bash
# Story 154 — standalone trimmer for ${ROOT}/implementations/.monitor-events/.
#
# Three drop conditions:
#   (a) file mtime > 24h → drop (catch-all).
#   (b) file's task-id not present in any agent tracker AND mtime > 1h → drop
#       (orphan-grace: lets a fresh post-compact restart re-read its own
#       recent events for the first hour).
#   (c) After drops, optionally rmdir empty per-purpose directories.
#
# M invokes this from startup; non-M roles don't sweep peer files. Until
# story 152's phase_sweep_monitor_events lands, this is the interim
# standalone trimmer with the same semantics.
#
# Honors WOW_ROOT override for test fixtures. Override the mtime threshold
# with WOW_MONITOR_EVENTS_MAX_HOURS (default 24) and the orphan-grace with
# WOW_MONITOR_EVENTS_ORPHAN_GRACE_HOURS (default 1).
#
# Exit codes: 0 success (always — silent no-op if dir missing or empty).

set -u

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
EVENTS_DIR="${WOW_ROOT}/implementations/.monitor-events"
AGENTS_DIR="${WOW_ROOT}/implementations/.agents"

MAX_HOURS="${WOW_MONITOR_EVENTS_MAX_HOURS:-24}"
ORPHAN_GRACE_HOURS="${WOW_MONITOR_EVENTS_ORPHAN_GRACE_HOURS:-1}"

# Convert hours to minutes for `find -mmin`.
MAX_MIN=$(( MAX_HOURS * 60 ))
ORPHAN_GRACE_MIN=$(( ORPHAN_GRACE_HOURS * 60 ))

if [ ! -d "$EVENTS_DIR" ]; then
  exit 0
fi

# Collect the set of task-ids that are referenced in any agent tracker
# (the *_task_id fields). Anything not in this set is an "orphan" file.
LIVE_TASK_IDS=""
if [ -d "$AGENTS_DIR" ]; then
  LIVE_TASK_IDS=$(jq -r '
    to_entries[] | select(.key | endswith("_task_id")) | .value | strings
  ' "$AGENTS_DIR"/*.json 2>/dev/null | sort -u || true)
fi

is_orphan() {
  local file_basename="$1"
  local task_id="${file_basename%.jsonl}"
  if [ -z "$LIVE_TASK_IDS" ]; then
    # No live trackers → every file is technically orphan. The mtime
    # gate below still applies (we don't blow away fresh files just
    # because trackers aren't on disk yet — orphan-grace).
    return 0
  fi
  if printf '%s\n' "$LIVE_TASK_IDS" | grep -qFx -- "$task_id"; then
    return 1
  fi
  return 0
}

# Walk every purpose dir.
for purpose_dir in "$EVENTS_DIR"/*/; do
  [ -d "$purpose_dir" ] || continue
  for file in "$purpose_dir"*.jsonl; do
    [ -f "$file" ] || continue
    base=$(basename "$file")

    # Drop condition (a): hard mtime cap.
    if [ "$(find "$file" -mmin +"$MAX_MIN" 2>/dev/null)" ]; then
      rm -f "$file" 2>/dev/null || true
      continue
    fi

    # Drop condition (b): orphan + past orphan-grace.
    if is_orphan "$base"; then
      if [ "$(find "$file" -mmin +"$ORPHAN_GRACE_MIN" 2>/dev/null)" ]; then
        rm -f "$file" 2>/dev/null || true
        continue
      fi
    fi
  done

  # Drop condition (c): rmdir if empty (best-effort).
  rmdir "$purpose_dir" 2>/dev/null || true
done

exit 0
