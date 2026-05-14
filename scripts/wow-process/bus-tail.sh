#!/usr/bin/env bash
# bus-tail.sh — emit bus lines relevant to the caller, surviving inode swaps.
#
# Usage: bus-tail.sh <bus-path> <agent-id> <role>
#
#   <bus-path>:  absolute path to implementations/.message-bus.jsonl
#   <agent-id>:  your full agent ID
#                (e.g. "senior-developer-20260416T162200-a4f9e2")
#   <role>:      your role prefix — one of:
#                "manager" | "senior-developer" | "pair-programmer"
#                | "tester" | "slacker"
#
# Transition layer (Story 059, introduced in v`<NEXT-to>`): when role is
# "senior-developer", lines addressed `to: "senior-dev-*"` ALSO match.
# Stderr emits `[bus-tail-deprecated-glob]` per legacy hit.
# Remove in v2.36 or later (after all peers migrated).
#
# A bus line is forwarded iff ALL of:
#   - it parses as valid JSON
#   - .from != <agent-id>                       (drop self-echoes)
#   - AND one of:
#       .to == "*"                               (broadcast)
#       .to == <agent-id>                        (direct to me)
#       .to == "<role>-*"                        (role-glob for my role)
#
# Implementation: a polling loop driven by a per-agent cursor file at
# `<bus-dir>/.agents/<agent-id>.bus-tail-cursor`. The cursor stores the line
# number of the last bus line this agent emitted. On each tick:
#
#   1. If the bus file's inode changed since the last tick, log a
#      [bus-tail-inode-swapped] notice to stderr (cursor is preserved).
#   2. wc -l the bus to get current line count.
#   3. If current < cursor (post-trim shrink), clamp cursor down — no replay.
#   4. If current > cursor, awk-extract lines [cursor+1..current], pipe
#      through jq with the predicate, emit matching lines to stdout, then
#      atomic-rewrite the cursor.
#
# Polling interval defaults to 250ms; configurable via BUS_TAIL_POLL_MS.
# Don't go below 100ms; don't go above 1000ms.
#
# Requirements: bash, jq 1.6+, awk, ls. macOS sleep accepts fractional
# seconds; busybox sleep on some Linux distros may round up to 1s — the
# script keeps working, latency just degrades to ~1s.
#
# `set -e` is intentionally absent — the polling loop must not exit on a
# transient error (jq parse failure, brief inode-swap window). Each tick is
# a fresh attempt; persistent errors surface as a stalled cursor.

set -u

BUS="${1:?bus path required (arg 1)}"
ID="${2:?agent id required (arg 2)}"
ROLE="${3:?role prefix required (arg 3)}"

PURPOSE="bus-tail"
CONFLICT_POLICY="kill"
WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$BUS")")}"
WOW_PROCESS_DIR="${WOW_ROOT}/implementations/.wow-process"
PIDFILE="${WOW_PROCESS_DIR}/${PURPOSE}-${ROLE}.pid"

CONF="${WOW_PROCESS_DIR}/${PURPOSE}.conf"
[ -f "$CONF" ] && . "$CONF"

if [ -f "$PIDFILE" ]; then
  PRIOR_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "${PRIOR_PID:-}" ] && kill -0 "$PRIOR_PID" 2>/dev/null; then
    case "$CONFLICT_POLICY" in
      kill)
        kill -TERM "$PRIOR_PID" 2>/dev/null || true
        sleep 2
        kill -0 "$PRIOR_PID" 2>/dev/null && kill -KILL "$PRIOR_PID" 2>/dev/null || true
        ;;
      raise)
        echo "[wow-process:${PURPOSE}] conflict: PID $PRIOR_PID alive; refusing to spawn" >&2
        exit 2
        ;;
    esac
  fi
fi

mkdir -p "$WOW_PROCESS_DIR"
echo "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
trap 'rm -f "$PIDFILE"; exit 130' INT TERM

ROLE_GLOB="${ROLE}-*"

# Story 059 transition layer: when role is "senior-developer", also accept
# legacy "senior-dev-*" addressing. Receive routing keys on `to` only;
# never on `from` (false-positive risk per PP review-fix 2026-05-03).
LEGACY_ROLE_GLOB=""
if [ "$ROLE" = "senior-developer" ]; then
  LEGACY_ROLE_GLOB="senior-dev-*"
fi

BUS_DIR="$(dirname "$BUS")"
CURSOR_DIR="$BUS_DIR/.agents"
CURSOR_FILE="$CURSOR_DIR/${ID}.bus-tail-cursor"
POLL_MS="${BUS_TAIL_POLL_MS:-250}"
POLL_S=$(awk "BEGIN { printf \"%.3f\", $POLL_MS / 1000 }")

mkdir -p "$CURSOR_DIR"
[ -f "$BUS" ] || touch "$BUS"

write_cursor() {
  printf '%d\n' "$1" > "$CURSOR_FILE.tmp.$$" \
    && mv -f "$CURSOR_FILE.tmp.$$" "$CURSOR_FILE"
}

current_lines() {
  wc -l < "$BUS" 2>/dev/null | tr -d ' '
}

current_inode() {
  ls -i "$BUS" 2>/dev/null | awk '{print $1}'
}

if [ -f "$CURSOR_FILE" ]; then
  cursor=$(cat "$CURSOR_FILE" 2>/dev/null | tr -d ' \n')
  [ -z "$cursor" ] && cursor=$(current_lines)
else
  cursor=$(current_lines)
fi
[ -z "$cursor" ] && cursor=0

last_inode=$(current_inode)

printf '[bus-tail-filter-armed] %s (agent=%s role-glob=%s)\n' \
  "$BUS" "$ID" "$ROLE_GLOB"

while true; do
  inode=$(current_inode)
  if [ -n "$inode" ] && [ -n "$last_inode" ] && [ "$inode" != "$last_inode" ]; then
    printf '[bus-tail-inode-swapped] %s\n' "$BUS" >&2
    last_inode="$inode"
  fi

  current=$(current_lines)
  [ -z "$current" ] && current=0

  if [ "$current" -lt "$cursor" ]; then
    cursor="$current"
    write_cursor "$cursor"
  fi

  if [ "$current" -gt "$cursor" ]; then
    start=$((cursor + 1))
    # First pass: scan range for the EARLIEST bus-restored line (introduced
    # in v2.22.0). Capture line number + payload.current_line_count. Lines
    # after that line up through current_line_count are SUPPRESSED in the
    # second pass; cursor advances past current_line_count.
    # PP nit on plan 024: split jq operator-precedence into separate selects.
    suppress_from=""
    fast_forward_to=""
    restored_marker=$(awk -v start="$start" -v end="$current" 'NR >= start && NR <= end {printf "%d\t%s\n", NR, $0}' "$BUS" \
      | jq -Rr 'split("\t") as $f | $f[1] | fromjson? | select(.type == "bus-restored") | select(.payload | type == "object") | select(.payload.current_line_count // empty | type == "number") | "\($f[0]) \(.payload.current_line_count)"' 2>/dev/null \
      | head -1)
    # Above: we want the line number prefix preserved alongside the JSON. The jq
    # filter above can't easily access $f[0] from awk-prefixed input. Fallback:
    # use a per-line bash loop that breaks early (head -1 at the outer pipe).
    if [ -z "$restored_marker" ]; then
      restored_marker=$(awk -v start="$start" -v end="$current" 'NR >= start && NR <= end {print NR ":" $0}' "$BUS" \
        | (while IFS= read -r tagged; do
            ln=${tagged%%:*}
            payload=${tagged#*:}
            ff=$(printf '%s' "$payload" | jq -r 'select(.type == "bus-restored") | select(.payload | type == "object") | select(.payload.current_line_count // empty | type == "number") | .payload.current_line_count' 2>/dev/null)
            if [ -n "$ff" ]; then
              printf '%s %s\n' "$ln" "$ff"
              break
            fi
          done))
    fi
    if [ -n "$restored_marker" ]; then
      suppress_from=$(printf '%s' "$restored_marker" | head -1 | awk '{print $1}')
      fast_forward_to=$(printf '%s' "$restored_marker" | head -1 | awk '{print $2}')
    fi
    # Second pass: emit lines, suppressing all gap lines from start through
    # fast_forward_to EXCEPT the bus-restored marker itself (which IS emitted
    # so consumers know to update local state). Per spec: cursor advances past
    # current_line_count and NO events for lines in [prev_cursor+1, ff_to].
    awk -v start="$start" -v end="$current" -v suppress_from="${suppress_from:-0}" -v ff="${fast_forward_to:-0}" \
      'NR >= start && NR <= end {
         if (suppress_from > 0 && NR != suppress_from && NR <= ff) next;
         print;
       }' "$BUS" \
      | jq -c --unbuffered \
          --arg id "$ID" \
          --arg role_glob "$ROLE_GLOB" \
          --arg legacy_glob "$LEGACY_ROLE_GLOB" \
          'select(
            .from != $id
            and (
              .to == "*"
              or .to == $id
              or .to == $role_glob
              or ($legacy_glob != "" and (.to | type == "string" and startswith("senior-dev-")))
            )
          )' 2>/dev/null

    # Story 059 transition-layer telemetry: emit a stderr deprecation line per
    # legacy `to` match. Catches BOTH the legacy glob (e.g. "senior-dev-*") AND
    # exact old-form IDs (e.g. "senior-dev-X"). Receive routing is to-only;
    # never key on `from` (false-positive risk). Runs only when LEGACY_ROLE_GLOB
    # is set (i.e. role is senior-developer).
    if [ -n "$LEGACY_ROLE_GLOB" ]; then
      awk -v start="$start" -v end="$current" -v suppress_from="${suppress_from:-0}" -v ff="${fast_forward_to:-0}" \
        'NR >= start && NR <= end {
           if (suppress_from > 0 && NR != suppress_from && NR <= ff) next;
           print;
         }' "$BUS" \
        | jq -r --unbuffered \
            'select(.to | type == "string" and startswith("senior-dev-")) | "to=\(.to) from=\(.from)"' \
            2>/dev/null \
        | sed 's/^/[bus-tail-deprecated-glob] /' >&2
    fi

    cursor="$current"
    if [ -n "$fast_forward_to" ] && [ "$fast_forward_to" -gt "$cursor" ]; then
      cursor="$fast_forward_to"
    fi
    write_cursor "$cursor"
  fi

  sleep "$POLL_S"
done
