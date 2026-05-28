#!/usr/bin/env bash
# Story 154 — full untruncated event roundtrip via monitor-pipe + monitor_event_read.
#
# Push a 5000-char event line through monitor-pipe.sh; read it back via
# the MCP tool monitor_event_read; assert byte-for-byte equality. This
# is the load-bearing test for "no silent truncation" — CC's Monitor
# truncates at ~500 chars, so without the wrapper a consumer would see
# a fragment; with the wrapper + tool, the consumer sees the full text.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected len=${#expected}, got len=${#actual})"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPE="$ROOT/scripts/wow-process/monitor-pipe.sh"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"

mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

PROJ=$(mk_project)

# Generate a 5000-char event (no newlines internally; one trailing \n
# at print time).
EVENT_5K=$(python3 -c 'import sys; sys.stdout.write("X"*5000)')
[ ${#EVENT_5K} -eq 5000 ] || { echo "test setup error: expected 5000 chars"; exit 1; }

# Push through the wrapper.
POINTER=$(printf '%s\n' "$EVENT_5K" \
  | WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id roundtrip5k)

# Pointer should be short (<500).
PTRLEN=${#POINTER}
if [ "$PTRLEN" -lt 500 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("pointer length $PTRLEN should be <500")
fi

# Read back via MCP tool.
ARGS='{"event_file":"implementations/.monitor-events/bus-tail/roundtrip5k.jsonl","line":1}'
RESP=$(CLAUDE_PROJECT_DIR="$PROJ" bash "$MCP_CALL" monitor_event_read "$ARGS")
RECOVERED=$(echo "$RESP" | jq -r '.result.content[0].text' | jq -r '.event')

# Byte-equality assertion.
assert_eq "5000-char event roundtrip" "$EVENT_5K" "$RECOVERED"

# Length sanity (catches truncation upstream of byte-equality).
ACTUAL_LEN=${#RECOVERED}
if [ "$ACTUAL_LEN" -eq 5000 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("recovered length $ACTUAL_LEN != 5000")
fi

rm -rf "$PROJ"

# ── Multi-line case: 100-line input, each line a unique payload, read back arbitrary lines
PROJ=$(mk_project)
INPUT=$(mktemp)
for i in $(seq 1 100); do
  printf 'event-%03d-with-some-trailing-padding-%s\n' "$i" "$(python3 -c "print('y'*100)")" >> "$INPUT"
done
cat "$INPUT" | WOW_ROOT="$PROJ" bash "$PIPE" --purpose bus-tail --task-id multi100 >/dev/null

# Read back line 1, line 42, line 100
EVENTS_FILE="$PROJ/implementations/.monitor-events/bus-tail/multi100.jsonl"
EXPECTED_1=$(sed -n '1p' "$EVENTS_FILE")
EXPECTED_42=$(sed -n '42p' "$EVENTS_FILE")
EXPECTED_100=$(sed -n '100p' "$EVENTS_FILE")

for LINE in 1 42 100; do
  case "$LINE" in
    1) EXP="$EXPECTED_1" ;;
    42) EXP="$EXPECTED_42" ;;
    100) EXP="$EXPECTED_100" ;;
  esac
  ARGS=$(printf '{"event_file":"implementations/.monitor-events/bus-tail/multi100.jsonl","line":%d}' "$LINE")
  RESP=$(CLAUDE_PROJECT_DIR="$PROJ" bash "$MCP_CALL" monitor_event_read "$ARGS")
  GOT=$(echo "$RESP" | jq -r '.result.content[0].text' | jq -r '.event')
  assert_eq "multi-line: line $LINE byte-equal" "$EXP" "$GOT"
done

rm -rf "$PROJ" "$INPUT"

# ── Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
