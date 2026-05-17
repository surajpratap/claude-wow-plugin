#!/usr/bin/env bash
# wow-bus-restore.sh — manual bus-restored handshake helper.
#
# Run this after a bus restoration that the per-agent cursor mechanism
# can't auto-detect (git pull replacing the bus, restore from backup,
# manual edit). The script appends a `bus-restored` line to the bus
# with the current line count; bus-tail.sh consumers fast-forward
# their cursors past the restored content.
#
# Usage:
#   bash scripts/wow-bus-restore.sh [--reason <text>]
#
# If M is alive (a manager-*.json offset tracker exists with
# `last_seen` within the last 5 minutes), the message is emitted with
# `from: manager-<active-id>` so peers see it as M-driven. Otherwise
# it's emitted with `from: bus-restore-helper-<6hex>` — peers still
# fast-forward; M (when next started) sees it as a routine peer-write.

set -u

REASON="manual restore via wow-bus-restore.sh"
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)
      shift
      REASON="${1:-$REASON}"
      shift
      ;;
    -h|--help)
      head -20 "$0" | tail -19
      exit 0
      ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BUS="$ROOT/implementations/.message-bus.jsonl"
AGENTS_DIR="$ROOT/implementations/.agents"

if [ ! -f "$BUS" ]; then
  printf 'wow-bus-restore: bus file not found at %s\n' "$BUS" >&2
  exit 2
fi

CURRENT_LINE_COUNT=$(wc -l < "$BUS" | tr -d ' ')

# Detect whether M is alive by scanning for manager-*.json with recent last_seen.
# Recent = within 5 min.
NOW_EPOCH=$(date -u +%s)
FIVE_MIN_AGO=$((NOW_EPOCH - 300))
FROM_ID=""

if [ -d "$AGENTS_DIR" ]; then
  for f in "$AGENTS_DIR"/manager-*.json; do
    [ -f "$f" ] || continue
    LAST_SEEN=$(jq -r '.last_seen // empty' "$f" 2>/dev/null)
    if [ -z "$LAST_SEEN" ] || [ "$LAST_SEEN" = "null" ]; then continue; fi
    LAST_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_SEEN" +%s 2>/dev/null \
      || date -u -d "$LAST_SEEN" +%s 2>/dev/null || true)
    if [ -n "$LAST_EPOCH" ] && [ "$LAST_EPOCH" -ge "$FIVE_MIN_AGO" ]; then
      MGR_ID=$(basename "$f" .json)
      FROM_ID="$MGR_ID"
      break
    fi
  done
fi

if [ -z "$FROM_ID" ]; then
  HEX=$(openssl rand -hex 3 2>/dev/null || printf '%06x' "$RANDOM$RANDOM" | head -c 6)
  FROM_ID="bus-restore-helper-${HEX}"
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -nc --arg ts "$TS" --arg from "$FROM_ID" --arg to "*" --arg type "bus-restored" \
  --arg reason "$REASON" --argjson clc "$CURRENT_LINE_COUNT" \
  '{ts:$ts, from:$from, to:$to, type:$type, payload:{reason:$reason, current_line_count:$clc}}' \
  >> "$BUS"

printf 'wow-bus-restore: emitted bus-restored from=%s to=* current_line_count=%s reason=%s\n' \
  "$FROM_ID" "$CURRENT_LINE_COUNT" "$REASON" >&2
