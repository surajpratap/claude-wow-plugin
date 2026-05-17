#!/usr/bin/env bash
# slack-events-trim.sh — opportunistic 1-week truncation of the Slack events feed.
#
# Story 094: extracted from the trim_events_feed doctrine helper in commands/slacker.md
# (mechanical-over-prose). Drops events.jsonl records older than 7 days once the file
# exceeds a threshold (default 2000 lines; per-project override via a sibling
# events-trim-threshold file holding a single integer).
#
# The feed's `ts` is the raw Slack message timestamp — a Unix-epoch decimal string
# (e.g. "1715426496.002500"); it doubles as the Slack message identifier, so it is
# left Slack-native. The cutoff is therefore a Unix epoch too and the jq comparison
# is numeric. Records with no `.ts` or a non-numeric `.ts` are dropped (tonumber? ->
# empty -> select drops). Atomic .tmp + mv; the `&&` is load-bearing — mv runs only
# on a jq exit 0, so a jq failure can never overwrite the live feed with a bad temp.
#
# Arg $1 = events.jsonl path (fallback ${ROOT}/implementations/.slack/events.jsonl).

set -u

EVENTS="${1:-${ROOT:-}/implementations/.slack/events.jsonl}"
[ -f "$EVENTS" ] || exit 0

EVENTS_DIR=$(dirname "$EVENTS")
THRESHOLD=2000
THRESHOLD_FILE="$EVENTS_DIR/events-trim-threshold"
[ -f "$THRESHOLD_FILE" ] && THRESHOLD=$(tr -d ' \n' < "$THRESHOLD_FILE")

LINES=$(wc -l < "$EVENTS" 2>/dev/null | tr -d ' '); LINES=${LINES:-0}
[ "$LINES" -ge "$THRESHOLD" ] || exit 0

# Cutoff as a Unix epoch (BSD `date` || GNU `date`), matching the feed's `ts`.
CUTOFF=$(date -u -v-7d +%s 2>/dev/null || date -u -d '7 days ago' +%s)
case "$CUTOFF" in
  '' | *[!0-9]*)
    echo "slack-events-trim: could not compute a numeric cutoff — skipping trim" >&2
    exit 0
    ;;
esac

TMP="$EVENTS.tmp.$$"
if jq -c --argjson cutoff "$CUTOFF" 'select((.ts | tonumber?) >= $cutoff)' \
     "$EVENTS" > "$TMP"; then
  mv "$TMP" "$EVENTS"
else
  rm -f "$TMP"
  echo "slack-events-trim: jq trim failed — feed left intact" >&2
  exit 1
fi
