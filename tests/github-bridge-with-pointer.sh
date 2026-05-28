#!/usr/bin/env bash
# Story 154 — github-bridge stdout pipes through monitor-pipe.sh.
#
# Pipeline:
#   bash github-bridge.sh ... | bash monitor-pipe.sh --purpose github-bridge
#
# Verifies (a) each upstream stdout line lands in the events file
# verbatim and (b) one short pointer per upstream line is emitted on
# stdout. Uses a synthetic stub upstream (no real github-bridge.sh
# spawn — that requires `gh` + repo state) — equivalent to testing
# the wrapper contract end-to-end with a known producer shape.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPE="$ROOT/scripts/wow-process/monitor-pipe.sh"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations/.monitor-events/github-bridge"

# Synthetic upstream: 3 JSONL bridge events as github-bridge.sh would emit.
UPSTREAM=$(mktemp)
cat > "$UPSTREAM" <<'EOF'
{"ts":"2026-05-28T12:00:00Z","from":"github-bridge-47823","type":"bridge-status","payload":{"state":"armed","reason":"initial"}}
{"ts":"2026-05-28T12:00:01Z","from":"github-bridge-47823","type":"pr-state","payload":{"repo":"o/r","pr":42,"from_state":"draft","to_state":"ready_for_review","actor":"someone","url":"https://x"}}
{"ts":"2026-05-28T12:00:02Z","from":"github-bridge-47823","type":"pr-review","payload":{"repo":"o/r","pr":42,"reviewer":"x","state":"approved","body":"LGTM","url":"https://x"}}
EOF

# Pipe through the wrapper and capture pointer stdout.
POINTERS=$(cat "$UPSTREAM" | WOW_ROOT="$PROJ" bash "$PIPE" --purpose github-bridge --task-id gh-pipeline)

POINTER_COUNT=$(printf '%s\n' "$POINTERS" | wc -l | tr -d ' ')
assert_eq "case1: 3 pointer lines on stdout" "3" "$POINTER_COUNT"

# Each pointer starts with [monitor:github-bridge]
GB_COUNT=$(printf '%s\n' "$POINTERS" | grep -c '^\[monitor:github-bridge\]' || true)
assert_eq "case1: 3 github-bridge-tagged pointers" "3" "$GB_COUNT"

# Events file has all 3 input lines verbatim
EVENTS="$PROJ/implementations/.monitor-events/github-bridge/gh-pipeline.jsonl"
EVENTS_COUNT=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case1: events file has 3 lines" "3" "$EVENTS_COUNT"

# Spot-check: line 2 should parse as JSON with type=pr-state
TYPE=$(sed -n '2p' "$EVENTS" | jq -r .type 2>/dev/null)
assert_eq "case1: events file line 2 type" "pr-state" "$TYPE"

rm -rf "$PROJ" "$UPSTREAM"

# ── Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
