#!/usr/bin/env bash
# Story 154 — manager-monitor stdout pipes through monitor-pipe.sh.
#
# Pipeline:
#   bash manager-monitor.sh | bash monitor-pipe.sh --purpose manager-monitor
#
# manager-monitor.py prints one JSONL `all-idle-nudge` line per detection.
# Synthetic upstream stub emits the canonical shape; assert wrapper
# persists + pointer-emits per line.

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
mkdir -p "$PROJ/implementations/.monitor-events/manager-monitor"

# Synthetic upstream — canonical all-idle-nudge shape.
UPSTREAM=$(mktemp)
cat > "$UPSTREAM" <<'EOF'
{"ts":"2026-05-28T12:00:00Z","from":"manager-monitor-pid12345","type":"all-idle-nudge","payload":{"agents":[{"role":"manager"},{"role":"sd"}]}}
{"ts":"2026-05-28T12:00:30Z","from":"manager-monitor-pid12345","type":"all-idle-nudge","payload":{"agents":[]}}
EOF

POINTERS=$(cat "$UPSTREAM" | WOW_ROOT="$PROJ" bash "$PIPE" --purpose manager-monitor --task-id im-pipeline)

POINTER_COUNT=$(printf '%s\n' "$POINTERS" | wc -l | tr -d ' ')
assert_eq "case1: 2 pointer lines on stdout" "2" "$POINTER_COUNT"

IM_COUNT=$(printf '%s\n' "$POINTERS" | grep -c '^\[monitor:manager-monitor\]' || true)
assert_eq "case1: 2 manager-monitor-tagged pointers" "2" "$IM_COUNT"

EVENTS="$PROJ/implementations/.monitor-events/manager-monitor/im-pipeline.jsonl"
EVENTS_COUNT=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case1: events file has 2 lines" "2" "$EVENTS_COUNT"

TYPE=$(sed -n '1p' "$EVENTS" | jq -r .type 2>/dev/null)
assert_eq "case1: events file line 1 type" "all-idle-nudge" "$TYPE"

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
