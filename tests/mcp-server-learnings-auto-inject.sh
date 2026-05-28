#!/usr/bin/env bash
# Story 124 — runtime test for the MCP server's read-learnings auto-inject
# in mcp/claude-wow-server/server.py handle_bus_emit.
#
# When called with type IN {story-created, sprint-kickoff, compaction-occurred}
# the server writes BOTH the original line AND a parallel read-learnings line
# in a SINGLE f.write() call. The inject's `to` field mirrors the original
# event's `to` (broadcast→broadcast, role-glob→role-glob, exact-ID→exact-ID).

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

assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"
SD="senior-developer-20260518T070000-aabbcc"
MGR="manager-20260518T070000-aabbcc"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

# Extract the read-learnings line from a bus file (it's always the LAST inject
# in the group — orig + token-discipline (maybe) + skill (maybe) + learnings).
last_learnings_line() {
  local bus="$1"
  grep '"type":"read-learnings"' "$bus" | tail -1
}

# -----------------------------------------------------------------------------
# Case (a): story-created (to: senior-developer-*) → learnings inject to same
# recipient glob.
# -----------------------------------------------------------------------------
PA=$(mk_project)
CLAUDE_PROJECT_DIR="$PA" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$MGR\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}" >/dev/null
LL_A=$(last_learnings_line "$PA/implementations/.message-bus.jsonl")
assert_eq "a-story-created-learnings-line-present" "yes" "$([ -n "$LL_A" ] && echo yes || echo no)"
assert_eq "a-learnings-to"    "senior-developer-*"                  "$(echo "$LL_A" | jq -r '.to // empty')"
assert_eq "a-learnings-from"  "$MGR"                                "$(echo "$LL_A" | jq -r '.from // empty')"
assert_eq "a-learnings-type"  "read-learnings"                      "$(echo "$LL_A" | jq -r '.type // empty')"
assert_eq "a-learnings-path"  "implementations/learnings/<role>.md" "$(echo "$LL_A" | jq -r '.payload.path // empty')"
assert_contains "a-learnings-reason" "auto-injected" "$(echo "$LL_A" | jq -r '.payload.reason // empty')"
rm -rf "$PA"

# -----------------------------------------------------------------------------
# Case (b): sprint-kickoff (to: *) → broadcast learnings inject.
# -----------------------------------------------------------------------------
PB=$(mk_project)
CLAUDE_PROJECT_DIR="$PB" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$MGR\",\"type\":\"sprint-kickoff\",\"to\":\"*\",\"payload\":{\"manifest\":\"x\"}}" >/dev/null
LL_B=$(last_learnings_line "$PB/implementations/.message-bus.jsonl")
assert_eq "b-sprint-kickoff-learnings-line-present" "yes" "$([ -n "$LL_B" ] && echo yes || echo no)"
assert_eq "b-learnings-to-broadcast" "*" "$(echo "$LL_B" | jq -r '.to // empty')"
rm -rf "$PB"

# -----------------------------------------------------------------------------
# Case (c): compaction-occurred (to: <exact-agent-id>) → learnings inject to
# the same exact ID. The hook fires while the agent is alive, so a tracker
# file exists for the receiving agent (mirroring real usage; required by
# Story 149's exact-ID liveness check).
# -----------------------------------------------------------------------------
PC=$(mk_project)
mkdir -p "$PC/implementations/.agents"
echo '{"last_line":0}' > "$PC/implementations/.agents/$SD.json"
CLAUDE_PROJECT_DIR="$PC" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"postcompact-hook-20260518T070000-aabbcc\",\"type\":\"compaction-occurred\",\"to\":\"$SD\",\"payload\":{\"agent_id\":\"$SD\"}}" >/dev/null
LL_C=$(last_learnings_line "$PC/implementations/.message-bus.jsonl")
assert_eq "c-compaction-learnings-line-present" "yes" "$([ -n "$LL_C" ] && echo yes || echo no)"
assert_eq "c-learnings-to-exact-id" "$SD" "$(echo "$LL_C" | jq -r '.to // empty')"
rm -rf "$PC"

# -----------------------------------------------------------------------------
# Case (d): NEGATIVE — a non-trigger type (status) emits NO read-learnings
# inject. Anti-regression against an over-fire on every event.
# -----------------------------------------------------------------------------
PD=$(mk_project)
CLAUDE_PROJECT_DIR="$PD" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$MGR\",\"type\":\"status\",\"to\":\"*\",\"payload\":{\"note\":\"x\"}}" >/dev/null
LL_D=$(last_learnings_line "$PD/implementations/.message-bus.jsonl")
assert_eq "d-status-no-learnings-line" "" "$LL_D"
rm -rf "$PD"

# -----------------------------------------------------------------------------
# Case (e): _agent-protocol.md has a read-learnings row in the message-types
# table — doc/code coherence guard.
# -----------------------------------------------------------------------------
if grep -q "read-learnings" "$ROOT/commands/_agent-protocol.md"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("e-doc-coherence (commands/_agent-protocol.md missing 'read-learnings' row)")
fi

# -----------------------------------------------------------------------------
# Case (f): each role file has a read-learnings event-handler bullet.
# -----------------------------------------------------------------------------
for role_file in manager senior-developer pair-programmer tester slacker; do
  if grep -q "read-learnings" "$ROOT/commands/${role_file}.md"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("f-role-handler-${role_file} (commands/${role_file}.md missing 'read-learnings' bullet)")
  fi
done

echo "mcp-server-learnings-auto-inject: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
