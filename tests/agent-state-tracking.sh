#!/usr/bin/env bash
# Story 061 — agent state tracking + TOTAL_CHILL_MODE prerequisites.
#
# Covers:
#   1.  set-state-active.sh: marker present → writes {state:active,...}
#   2.  set-state-chilling.sh: marker present → writes {state:chilling,...}
#   3.  log-activity.sh extended: also writes active to actual-state (double-job)
#   4.  wow-set-expected-state.sh: valid role+state → writes
#   5.  wow-set-expected-state.sh: invalid role → exit 1, no write
#   6.  m-state-compare.sh: exp=active, act=active, age=2min → no output
#   7.  m-state-compare.sh: exp=active, act=active, age=15min → [state-stale]
#   8.  m-state-compare.sh: exp=chilling, act=chilling, age=15min → [state-stale]
#   9.  m-state-compare.sh: exp=active, act=chilling → [state-mismatch]
#   10. mcp__claude-wow__bus_emit: valid type+to → line appended, valid JSON shape
#   11. mcp__claude-wow__bus_emit: invalid type → JSON-RPC error, nothing written
#   12. m-state-compare.sh: exp=absent, act=absent → silent (extra coverage)
#   13. mcp__claude-wow__bus_emit: missing `from` arg → JSON-RPC error, nothing written
#   14. mcp__claude-wow__bus_emit: `from` arg lands in emitted line's `from` field
#   15. mcp__claude-wow__bus_emit: AGENT_ID env var is NOT a fallback → error (negative)
#   16. mcp__claude-wow__bus_emit: `payload` with apostrophe + backtick preserved verbatim

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

assert_true() {
  local name="$1"; local rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected rc=0, got rc=$rc)")
  fi
}

assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle': '$hay')") ;;
  esac
}

assert_empty() {
  local name="$1"; local val="$2"
  if [ -z "$val" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected empty, got '$val')")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$(cd "$ROOT/.." && pwd)"
SET_ACTIVE="$ROOT/scripts/hooks/set-state-active.sh"
SET_CHILLING="$ROOT/scripts/hooks/set-state-chilling.sh"
LOG_ACTIVITY="$ROOT/scripts/hooks/log-activity.sh"
SET_EXPECTED="$SOURCE_ROOT/scripts/wow-set-expected-state.sh"
COMPARE="$SOURCE_ROOT/scripts/m-state-compare.sh"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"  # Story 062: MCP-tool replacement for bus-emit.sh

# Story 062 helper: invoke bus_emit MCP tool with given args JSON.
# Uses CLAUDE_PROJECT_DIR (caller controls bus path via env).
mcp_bus_emit() {
  bash "$MCP_CALL" bus_emit "$1" 2>/dev/null
}

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo "$d"
}

# -----------------------------------------------------------------------------
# Case 1: set-state-active.sh writes active line
# -----------------------------------------------------------------------------
P1=$(mk_project)
echo "senior-developer" > "$P1/.claude/.session-role-by-claude-pid/$$"
echo '{"prompt":"hi"}' | CLAUDE_PROJECT_DIR="$P1" bash "$SET_ACTIVE"
LINE1=$(cat "$P1/implementations/.actual-state/senior-developer.jsonl" 2>/dev/null)
S1=$(echo "$LINE1" | jq -r '.state // empty')
assert_eq "case-1-set-active-state-field" "active" "$S1"
A1=$(echo "$LINE1" | jq -r '.agent_id // empty')
assert_eq "case-1-set-active-agent-id" "senior-developer" "$A1"
rm -rf "$P1"

# -----------------------------------------------------------------------------
# Case 2: set-state-chilling.sh writes chilling line
# -----------------------------------------------------------------------------
P2=$(mk_project)
echo "tester" > "$P2/.claude/.session-role-by-claude-pid/$$"
echo '{"stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$P2" bash "$SET_CHILLING"
LINE2=$(cat "$P2/implementations/.actual-state/tester.jsonl" 2>/dev/null)
S2=$(echo "$LINE2" | jq -r '.state // empty')
assert_eq "case-2-set-chilling-state-field" "chilling" "$S2"
rm -rf "$P2"

# -----------------------------------------------------------------------------
# Case 3: log-activity.sh extended → also writes actual-state=active
# -----------------------------------------------------------------------------
P3=$(mk_project)
echo "pair-programmer" > "$P3/.claude/.session-role-by-claude-pid/$$"
echo '{"tool_name":"Bash"}' | CLAUDE_PROJECT_DIR="$P3" bash "$LOG_ACTIVITY"
[ -f "$P3/implementations/.activity.jsonl" ] && ACT_LOG_OK=ok || ACT_LOG_OK=missing
[ -f "$P3/implementations/.actual-state/pair-programmer.jsonl" ] && STATE_OK=ok || STATE_OK=missing
assert_eq "case-3-log-activity-still-writes-activity" "ok" "$ACT_LOG_OK"
assert_eq "case-3-log-activity-also-writes-state" "ok" "$STATE_OK"
S3=$(jq -r '.state // empty' "$P3/implementations/.actual-state/pair-programmer.jsonl" 2>/dev/null)
assert_eq "case-3-state-is-active" "active" "$S3"
rm -rf "$P3"

# -----------------------------------------------------------------------------
# Case 4: wow-set-expected-state.sh valid role+state → writes
# -----------------------------------------------------------------------------
P4=$(mk_project)
ROOT_BAK="$ROOT"
ROOT="$P4" bash "$SET_EXPECTED" senior-developer active 2>/dev/null
ROOT="$ROOT_BAK"
LINE4=$(cat "$P4/implementations/.expected-state/senior-developer.jsonl" 2>/dev/null)
S4=$(echo "$LINE4" | jq -r '.state // empty')
assert_eq "case-4-set-expected-state-field" "active" "$S4"
rm -rf "$P4"

# -----------------------------------------------------------------------------
# Case 5: wow-set-expected-state.sh invalid role → exit 1, no write
# -----------------------------------------------------------------------------
P5=$(mk_project)
STDERR_FILE=$(mktemp)
ROOT="$P5" bash "$SET_EXPECTED" manager active 2>"$STDERR_FILE"
RC5=$?
ERR5=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"
[ -f "$P5/implementations/.expected-state/manager.jsonl" ] && WROTE5=yes || WROTE5=no
assert_eq "case-5-invalid-role-exit-1" "1" "$RC5"
assert_eq "case-5-invalid-role-no-write" "no" "$WROTE5"
assert_contains "case-5-stderr-names-allowed" "pair-programmer" "$ERR5"
rm -rf "$P5"

# -----------------------------------------------------------------------------
# Case 6: m-state-compare.sh exp=active, act=active, age=2min → silent
# -----------------------------------------------------------------------------
P6=$(mk_project)
mkdir -p "$P6/implementations/.expected-state" "$P6/implementations/.actual-state"
NOW6=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS6_2MIN=$(date -u -v-2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
echo "{\"state\":\"active\",\"ts\":\"$NOW6\"}" > "$P6/implementations/.expected-state/senior-developer.jsonl"
echo "{\"state\":\"active\",\"ts\":\"$TS6_2MIN\"}" > "$P6/implementations/.actual-state/senior-developer.jsonl"
OUT6=$(ROOT="$P6" bash "$COMPARE")
assert_empty "case-6-active-active-2min-silent" "$OUT6"
rm -rf "$P6"

# -----------------------------------------------------------------------------
# Case 7: m-state-compare.sh exp=active, act=active, age=15min → [state-stale]
# -----------------------------------------------------------------------------
P7=$(mk_project)
mkdir -p "$P7/implementations/.expected-state" "$P7/implementations/.actual-state"
NOW7=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS7_15MIN=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
echo "{\"state\":\"active\",\"ts\":\"$NOW7\"}" > "$P7/implementations/.expected-state/senior-developer.jsonl"
echo "{\"state\":\"active\",\"ts\":\"$TS7_15MIN\"}" > "$P7/implementations/.actual-state/senior-developer.jsonl"
OUT7=$(ROOT="$P7" bash "$COMPARE")
assert_contains "case-7-active-active-15min-stale" "[state-stale] senior-developer:" "$OUT7"
rm -rf "$P7"

# -----------------------------------------------------------------------------
# Case 8: exp=chilling, act=chilling, age=15min → [state-stale]
# -----------------------------------------------------------------------------
P8=$(mk_project)
mkdir -p "$P8/implementations/.expected-state" "$P8/implementations/.actual-state"
NOW8=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS8_15MIN=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
echo "{\"state\":\"chilling\",\"ts\":\"$NOW8\"}" > "$P8/implementations/.expected-state/tester.jsonl"
echo "{\"state\":\"chilling\",\"ts\":\"$TS8_15MIN\"}" > "$P8/implementations/.actual-state/tester.jsonl"
OUT8=$(ROOT="$P8" bash "$COMPARE")
assert_contains "case-8-chilling-chilling-15min-stale" "[state-stale] tester:" "$OUT8"
rm -rf "$P8"

# -----------------------------------------------------------------------------
# Case 9: exp=active, act=chilling → [state-mismatch]
# -----------------------------------------------------------------------------
P9=$(mk_project)
mkdir -p "$P9/implementations/.expected-state" "$P9/implementations/.actual-state"
NOW9=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "{\"state\":\"active\",\"ts\":\"$NOW9\"}" > "$P9/implementations/.expected-state/pair-programmer.jsonl"
echo "{\"state\":\"chilling\",\"ts\":\"$NOW9\"}" > "$P9/implementations/.actual-state/pair-programmer.jsonl"
OUT9=$(ROOT="$P9" bash "$COMPARE")
assert_contains "case-9-active-chilling-mismatch" "[state-mismatch] pair-programmer:" "$OUT9"
assert_contains "case-9-mismatch-includes-expected" "expected=active" "$OUT9"
assert_contains "case-9-mismatch-includes-actual" "actual=chilling" "$OUT9"
rm -rf "$P9"

# -----------------------------------------------------------------------------
# Case 10: mcp__claude-wow__bus_emit valid type+to → line appended, valid JSON
# -----------------------------------------------------------------------------
P10=$(mk_project)
mkdir -p "$P10/implementations" && touch "$P10/implementations/.message-bus.jsonl"
CLAUDE_PROJECT_DIR="$P10" mcp_bus_emit \
  '{"from":"senior-developer-20260504T070000-abcdef","type":"ping","to":"manager-*"}' >/dev/null
LINE10=$(tail -1 "$P10/implementations/.message-bus.jsonl")
echo "$LINE10" | jq -e . >/dev/null 2>&1
assert_true "case-10-valid-emit-valid-json" "$?"
T10=$(echo "$LINE10" | jq -r '.type // empty')
assert_eq "case-10-type-field" "ping" "$T10"
rm -rf "$P10"

# -----------------------------------------------------------------------------
# Case 11: mcp__claude-wow__bus_emit invalid type → JSON-RPC error, nothing written
# -----------------------------------------------------------------------------
P11=$(mk_project)
mkdir -p "$P11/implementations" && touch "$P11/implementations/.message-bus.jsonl"
RESP11=$(CLAUDE_PROJECT_DIR="$P11" mcp_bus_emit \
  '{"from":"manager-20260504T070000-abcdef","type":"bogus-type","to":"*"}')
HAS_ERR11=$(echo "$RESP11" | jq -r 'has("error")')
LINES11=$(wc -l < "$P11/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-11-invalid-type-error" "true" "$HAS_ERR11"
assert_eq "case-11-invalid-type-no-write" "0" "$LINES11"
rm -rf "$P11"

# -----------------------------------------------------------------------------
# Case 12: m-state-compare.sh exp=absent, act=absent → silent
# -----------------------------------------------------------------------------
P12=$(mk_project)
# No state files at all.
OUT12=$(ROOT="$P12" bash "$COMPARE")
assert_empty "case-12-absent-absent-silent" "$OUT12"
rm -rf "$P12"

# -----------------------------------------------------------------------------
# Case 13: mcp__claude-wow__bus_emit missing `from` arg → JSON-RPC error, nothing written
# -----------------------------------------------------------------------------
P13=$(mk_project)
mkdir -p "$P13/implementations" && touch "$P13/implementations/.message-bus.jsonl"
RESP13=$(CLAUDE_PROJECT_DIR="$P13" mcp_bus_emit \
  '{"type":"ping","to":"*"}')
HAS_ERR13=$(echo "$RESP13" | jq -r 'has("error")')
LINES13=$(wc -l < "$P13/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-13-missing-from-error" "true" "$HAS_ERR13"
assert_eq "case-13-missing-from-no-write" "0" "$LINES13"
rm -rf "$P13"

# -----------------------------------------------------------------------------
# Case 14: mcp__claude-wow__bus_emit `from` arg lands in `from` field
# -----------------------------------------------------------------------------
P14=$(mk_project)
mkdir -p "$P14/implementations" && touch "$P14/implementations/.message-bus.jsonl"
CLAUDE_PROJECT_DIR="$P14" mcp_bus_emit \
  '{"from":"tester-20260504T070000-abcdef","type":"ping","to":"*"}' >/dev/null
F14=$(tail -1 "$P14/implementations/.message-bus.jsonl" | jq -r '.from // empty')
assert_eq "case-14-from-arg-lands" "tester-20260504T070000-abcdef" "$F14"
rm -rf "$P14"

# -----------------------------------------------------------------------------
# Case 15: AGENT_ID env var is NOT a fallback (negative coverage, Story 062).
# Legacy bus-emit.sh used $AGENT_ID when --from was missing. MCP server is
# strict — even with AGENT_ID set, missing `from` arg → JSON-RPC error.
# Callers (role-file directives) must pass `from` explicitly.
# -----------------------------------------------------------------------------
P15=$(mk_project)
mkdir -p "$P15/implementations" && touch "$P15/implementations/.message-bus.jsonl"
RESP15=$(AGENT_ID="manager-20260504T070000-abcdef" CLAUDE_PROJECT_DIR="$P15" mcp_bus_emit \
  '{"type":"ping","to":"*"}')
HAS_ERR15=$(echo "$RESP15" | jq -r 'has("error")')
LINES15=$(wc -l < "$P15/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-15-env-not-fallback-error" "true" "$HAS_ERR15"
assert_eq "case-15-env-not-fallback-no-write" "0" "$LINES15"
unset AGENT_ID
rm -rf "$P15"

# -----------------------------------------------------------------------------
# Case 16: mcp__claude-wow__bus_emit `payload` with apostrophe + backtick preserved
# -----------------------------------------------------------------------------
P16=$(mk_project)
mkdir -p "$P16/implementations" && touch "$P16/implementations/.message-bus.jsonl"
PAYLOAD16='{"summary":"Claude Code'"'"'s `tool` ran","details":["one","two"]}'
ARGS16=$(jq -cn --argjson p "$PAYLOAD16" \
  '{from:"manager-20260504T070000-abcdef",type:"status",to:"*",payload:$p}')
CLAUDE_PROJECT_DIR="$P16" mcp_bus_emit "$ARGS16" >/dev/null
SUM16=$(tail -1 "$P16/implementations/.message-bus.jsonl" | jq -r '.payload.summary // empty')
assert_contains "case-16-apostrophe-preserved" "Claude Code's" "$SUM16"
assert_contains "case-16-backtick-preserved" '`tool`' "$SUM16"
rm -rf "$P16"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "agent-state-tracking: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
