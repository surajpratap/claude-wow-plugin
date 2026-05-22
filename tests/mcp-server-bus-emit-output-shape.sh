#!/usr/bin/env bash
# Story 134 — mechanical pin of the bus_emit on-disk output shape.
#
# Closes the FINDING-32 class: SD/PP-round-1/T all reasoned from the bus_emit
# MCP INPUT schema instead of the server-SERIALIZED output. The server wraps
# `in_reply_to` at `mcp/claude-wow-server/server.py:335`:
#     line["in_reply_to"] = {"ts": in_reply_to}
# So the on-disk shape is `.in_reply_to.ts`, not a flat string. A jq filter
# `.in_reply_to >= $cutoff` compares a dict to a string and is always-true
# (objects sort after strings in jq). This test pins every field the server
# transforms — future code/review walking the bus has a one-grep source-of-
# truth.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"
SENDER="manager-20260521T091400-aabbcc"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

# ---- Case (a): in_reply_to wraps to a {ts:…} object on disk ----
# Caller passes a flat string per the MCP input schema; server wraps it.
PA=$(mk_project)
CUTOFF="2026-05-21T05:58:22Z"
CLAUDE_PROJECT_DIR="$PA" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"pong\",\"to\":\"manager-*\",\"in_reply_to\":\"$CUTOFF\",\"payload\":{\"k\":\"v\"}}" >/dev/null
LINE_A=$(head -1 "$PA/implementations/.message-bus.jsonl")
IR_TYPE_A=$(echo "$LINE_A" | jq -r '.in_reply_to | type')
IR_TS_A=$(echo "$LINE_A" | jq -r '.in_reply_to.ts // empty')
assert_eq "a-in_reply_to-is-object"   "object"   "$IR_TYPE_A"
assert_eq "a-in_reply_to-ts-roundtrips" "$CUTOFF" "$IR_TS_A"
# Anti-revert: a future server change that drops the wrap (back to flat
# string) flips .in_reply_to | type → "string", failing case-a.
case "$IR_TYPE_A" in
  string)
    FAIL=$((FAIL+1))
    FAILED_CASES+=("a-anti-revert-flat-string (in_reply_to serialized as flat string — FINDING-32 always-true jq bug shape)") ;;
  *) PASS=$((PASS+1)) ;;
esac
rm -rf "$PA"

# ---- Case (b): payload passes through verbatim (server does NOT wrap) ----
PB=$(mk_project)
PAYLOAD='{"k":"v","n":42,"nested":{"x":["a","b"]}}'
CLAUDE_PROJECT_DIR="$PB" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"status\",\"to\":\"*\",\"payload\":$PAYLOAD}" >/dev/null
LINE_B=$(head -1 "$PB/implementations/.message-bus.jsonl")
assert_eq "b-payload-k"        "v"  "$(echo "$LINE_B" | jq -r '.payload.k // empty')"
assert_eq "b-payload-n"        "42" "$(echo "$LINE_B" | jq -r '.payload.n // empty')"
assert_eq "b-payload-nested-x" "b"  "$(echo "$LINE_B" | jq -r '.payload.nested.x[1] // empty')"
rm -rf "$PB"

# ---- Case (c): from / to / type / ts pass through verbatim ----
PC=$(mk_project)
CLAUDE_PROJECT_DIR="$PC" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"ping\",\"to\":\"manager-*\",\"payload\":\"x\"}" >/dev/null
LINE_C=$(head -1 "$PC/implementations/.message-bus.jsonl")
assert_eq "c-from-verbatim" "$SENDER"    "$(echo "$LINE_C" | jq -r '.from // empty')"
assert_eq "c-to-verbatim"   "manager-*"  "$(echo "$LINE_C" | jq -r '.to // empty')"
assert_eq "c-type-verbatim" "ping"       "$(echo "$LINE_C" | jq -r '.type // empty')"
# ts is server-set to UTC ISO 8601 (Z suffix); shape check, not exact match.
TS_C=$(echo "$LINE_C" | jq -r '.ts // empty')
case "$TS_C" in
  20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1))
     FAILED_CASES+=("c-ts-shape (.ts='$TS_C' is not YYYY-MM-DDTHH:MM:SSZ)") ;;
esac
rm -rf "$PC"

# ---- Case (d): in_reply_to absent → field absent on disk (wrap is gated) ----
PD=$(mk_project)
CLAUDE_PROJECT_DIR="$PD" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"status\",\"to\":\"*\",\"payload\":\"x\"}" >/dev/null
LINE_D=$(head -1 "$PD/implementations/.message-bus.jsonl")
assert_eq "d-no-in_reply_to-no-field" "ABSENT" \
  "$(echo "$LINE_D" | jq -r '.in_reply_to // "ABSENT"')"
rm -rf "$PD"

# ---- Case (e): emitted line is valid JSON (sanity) ----
PE=$(mk_project)
CLAUDE_PROJECT_DIR="$PE" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"status\",\"to\":\"*\",\"payload\":{\"k\":\"v\"}}" >/dev/null
LINE_E=$(head -1 "$PE/implementations/.message-bus.jsonl")
if echo "$LINE_E" | jq -e . >/dev/null 2>&1; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("e-line-is-valid-json (bus line failed jq -e .)")
fi
rm -rf "$PE"

# Story 141 — reference adoption: a bus-message fixture with the nested
# in_reply_to:{ts} wrap validates against the golden (would catch a flat-string regression).
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")" && pwd)/lib/contract-golden.sh"
if assert_fixture_matches_golden bus-message '{"ts":"t","from":"f","to":"manager-*","type":"pong","payload":{"nonce":"x"},"in_reply_to":{"ts":"t2"}}' 2>/dev/null; then
  PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("141-golden: bus-message fixture diverges from golden"); fi

echo "mcp-server-bus-emit-output-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
