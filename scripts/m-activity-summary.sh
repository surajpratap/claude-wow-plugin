#!/usr/bin/env bash
# scripts/m-activity-summary.sh — read .activity.jsonl, summarize per-role
# last-activity-ts since a given timestamp (default: now - 5 min).
#
# Story 058. Sourceable + CLI-invocable.
#
# Usage: bash scripts/m-activity-summary.sh [<since-iso>]
#
# Output (stdout): JSON object
#   {
#     "by_role": {"manager": <ts|null>, "senior-developer": <ts|null>, ...},
#     "total_lines_since": <int>,
#     "since": "<iso>"
#   }
#
# Empty/missing log → all roles null, total_lines_since: 0, exit 0.
# Always exits 0 (errors are silent — empty input means no activity, which
# is a valid state to report). Stderr is the diagnostic channel.

set -u

_m_activity_summary() {
  local since="${1:-}"
  if [ -z "$since" ]; then
    since=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  fi
  if [ -z "$since" ]; then
    echo "m-activity-summary: could not compute default since (date util missing?) — skipping" >&2
    return 0
  fi

  local root="${ROOT:-}"
  if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi
  local log="$root/implementations/.activity.jsonl"

  if [ ! -f "$log" ]; then
    jq -nc --arg s "$since" \
      '{by_role:{manager:null,"senior-developer":null,"pair-programmer":null,tester:null,slacker:null}, total_lines_since:0, since:$s}'
    return 0
  fi

  jq -sc --arg s "$since" '
    map(select(.ts >= $s))
    | {
        by_role: (
          {manager:null,"senior-developer":null,"pair-programmer":null,tester:null,slacker:null}
          + (group_by(.role) | map({key: .[0].role, value: (max_by(.ts).ts)}) | from_entries)
        ),
        total_lines_since: length,
        since: $s
      }
  ' "$log" 2>/dev/null || \
    jq -nc --arg s "$since" \
      '{by_role:{manager:null,"senior-developer":null,"pair-programmer":null,tester:null,slacker:null}, total_lines_since:0, since:$s}'
}

if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
  return 0 2>/dev/null || true
fi

_m_activity_summary "$@"
