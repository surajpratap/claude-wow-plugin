#!/usr/bin/env bash
# Story 101 — runtime test for the MCP server's role<->skill auto-inject in
# mcp/claude-wow-server/server.py handle_bus_emit.
#
# When bus_emit is called with a type in SKILL_INJECT_MAP, the server writes
# an extra `read-skill` reminder line addressed to the skill-owner role —
# ADDITIVE: it fires alongside any doctrine inject (a story-created emits the
# original + read-token-discipline + read-skill, all in one f.write).

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
SERVER="$ROOT/mcp/claude-wow-server/server.py"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"
SD="senior-developer-20260518T070000-aabbcc"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

emit() {
  # $1 = project dir, $2 = bus_emit JSON args
  CLAUDE_PROJECT_DIR="$1" bash "$MCP_CALL" bus_emit "$2" >/dev/null
}

# Case (a): story-created → 3 lines; line 3 is the read-skill reminder.
PA=$(mk_project)
emit "$PA" "{\"from\":\"$SD\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}"
assert_eq "a-story-created-3-lines" "3" "$(wc -l < "$PA/implementations/.message-bus.jsonl" | tr -d ' ')"
L3=$(sed -n '3p' "$PA/implementations/.message-bus.jsonl")
assert_eq "a-line3-type"  "read-skill"               "$(echo "$L3" | jq -r '.type // empty')"
assert_eq "a-line3-to"    "senior-developer-*"        "$(echo "$L3" | jq -r '.to // empty')"
assert_eq "a-line3-skill" "superpowers:writing-plans" "$(echo "$L3" | jq -r '.payload.skill // empty')"
rm -rf "$PA"

# Case (b): plan-approved → 2 lines (no doctrine inject); line 2 read-skill.
PB=$(mk_project)
emit "$PB" "{\"from\":\"pair-programmer-20260518T070000-aabbcc\",\"type\":\"plan-approved\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}"
assert_eq "b-plan-approved-2-lines" "2" "$(wc -l < "$PB/implementations/.message-bus.jsonl" | tr -d ' ')"
L2B=$(sed -n '2p' "$PB/implementations/.message-bus.jsonl")
assert_eq "b-line2-type"  "read-skill"                  "$(echo "$L2B" | jq -r '.type // empty')"
assert_eq "b-line2-to"    "senior-developer-*"           "$(echo "$L2B" | jq -r '.to // empty')"
assert_eq "b-line2-skill" "superpowers:executing-plans"  "$(echo "$L2B" | jq -r '.payload.skill // empty')"
rm -rf "$PB"

# Case (c): story-done → 2 lines; line 2 read-skill → T verification skill.
PC=$(mk_project)
emit "$PC" "{\"from\":\"$SD\",\"type\":\"story-done\",\"to\":\"tester-*\",\"payload\":{\"ref\":\"x\"}}"
assert_eq "c-story-done-2-lines" "2" "$(wc -l < "$PC/implementations/.message-bus.jsonl" | tr -d ' ')"
L2C=$(sed -n '2p' "$PC/implementations/.message-bus.jsonl")
assert_eq "c-line2-type"  "read-skill"                            "$(echo "$L2C" | jq -r '.type // empty')"
assert_eq "c-line2-to"    "tester-*"                              "$(echo "$L2C" | jq -r '.to // empty')"
assert_eq "c-line2-skill" "superpowers:verification-before-completion" "$(echo "$L2C" | jq -r '.payload.skill // empty')"
rm -rf "$PC"

# Case (d): a non-trigger type (status) → 1 line, no read-skill.
PD=$(mk_project)
emit "$PD" "{\"from\":\"$SD\",\"type\":\"status\",\"to\":\"*\",\"payload\":{\"note\":\"x\"}}"
assert_eq "d-status-1-line" "1" "$(wc -l < "$PD/implementations/.message-bus.jsonl" | tr -d ' ')"
rm -rf "$PD"

# Case (e): read-skill envelope shape — ts/from/to/type/payload.{skill,event,reason}.
PE=$(mk_project)
emit "$PE" "{\"from\":\"$SD\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}"
LE=$(sed -n '3p' "$PE/implementations/.message-bus.jsonl")
assert_eq "e-from"           "$SD"                "$(echo "$LE" | jq -r '.from // empty')"
assert_eq "e-event"          "story-created"      "$(echo "$LE" | jq -r '.payload.event // empty')"
assert_eq "e-ts-present"     "yes"                "$([ -n "$(echo "$LE" | jq -r '.ts // empty')" ] && echo yes || echo no)"
assert_eq "e-reason-present" "yes"                "$(echo "$LE" | jq -r '.payload.reason // empty' | grep -q 'auto-injected' && echo yes || echo no)"
rm -rf "$PE"

# Case (f): regression — story-created STILL also emits read-token-discipline
# (line 2). The additive skill block did not displace the doctrine inject.
PF=$(mk_project)
emit "$PF" "{\"from\":\"$SD\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}"
assert_eq "f-line2-still-token-discipline" "read-token-discipline" \
  "$(sed -n '2p' "$PF/implementations/.message-bus.jsonl" | jq -r '.type // empty')"
rm -rf "$PF"

# Case (g): read-skill is in ALLOWED_TYPES — a direct bus_emit of read-skill is
# accepted (1 line appended), not rejected. The auto-inject cases above would
# all pass even without the enum entry (the server writes injects directly,
# bypassing bus_emit validation) — so the enum needs its own assertion.
PG=$(mk_project)
emit "$PG" "{\"from\":\"$SD\",\"type\":\"read-skill\",\"to\":\"senior-developer-*\",\"payload\":{\"skill\":\"x\"}}"
assert_eq "g-read-skill-accepted" "1" "$(wc -l < "$PG/implementations/.message-bus.jsonl" | tr -d ' ')"
rm -rf "$PG"

# Case (h): contiguity — a story-created's 3 lines are exactly
# [story-created, read-token-discipline, read-skill] in order (one f.write).
PH=$(mk_project)
emit "$PH" "{\"from\":\"$SD\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}"
TYPES_H=$(jq -r '.type' "$PH/implementations/.message-bus.jsonl" | tr '\n' ',')
assert_eq "h-contiguous-3-line-group" "story-created,read-token-discipline,read-skill," "$TYPES_H"
rm -rf "$PH"

echo "mcp-server-skill-auto-inject: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
