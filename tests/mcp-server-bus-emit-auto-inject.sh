#!/usr/bin/env bash
# Story 069 amendment-3 — runtime test for the MCP server's auto-inject
# behavior in mcp/claude-wow-server/server.py handle_bus_emit.
#
# When called with type IN {story-created, sprint-kickoff} the server
# writes BOTH the original line AND a parallel read-token-discipline
# broadcast in a SINGLE f.write() call inside one with-open block.
# Single-syscall atomicity for writes <= PIPE_BUF means both lines or
# neither — concurrent emits never interleave their pairs.
#
# 8 runtime assertions (drives the live server via tests/fixtures/mcp-call.sh):
#   (a)   story-created       -> exactly 2 bus lines
#   (b)   sprint-kickoff      -> exactly 2 bus lines
#   (c)   story-done          -> exactly 1 bus line  (non-trigger type)
#   (d1)  auto-injected line type == read-token-discipline
#   (d2)  auto-injected line to == *
#   (d3)  auto-injected line from == original sender
#   (d4)  auto-injected line payload.path == commands/_token-discipline.md
#   (d5)  auto-injected line payload.reason contains "auto-injected"
#   (e)   single-write atomicity under concurrency: 5 parallel story-created
#         calls produce exactly 10 lines AND every read-token-discipline line
#         immediately follows its paired story-created (no interleaving)
#
# Plus 4 doc-shape assertions:
#   (f)   commands/_agent-protocol.md has a read-token-discipline row
#   (g)   all 5 peer role files have a bus-handler entry for read-token-discipline
#   (h)   all 5 peer role files have a startup-read step for commands/_token-discipline.md
#   (i)   NEGATIVE — commands/_agent-protocol.md story-created row does NOT
#         contain token_discipline_doctrine (per amendment-1 inline-payload
#         removal; this guards against regression)
#   (j)   pr-created auto-injects a code-review-request to pair-programmer-*
#         carrying the original pr-created payload
#   (k)   commands/_agent-protocol.md has a code-review-request row

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

assert_match() {
  local name="$1"; local file="$2"; local pattern="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (no match for /$pattern/ in $file)")
  fi
}

assert_no_match() {
  local name="$1"; local file="$2"; local pattern="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (unexpected match for /$pattern/ in $file)")
  else
    PASS=$((PASS+1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$ROOT/mcp/claude-wow-server/server.py"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"
SENDER="senior-developer-20260508T120000-aabbcc"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

# -----------------------------------------------------------------------------
# Case (a): story-created emits 2 bus lines (original + auto-injected).
# -----------------------------------------------------------------------------
PA=$(mk_project)
CLAUDE_PROJECT_DIR="$PA" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}" >/dev/null
LINES_A=$(wc -l < "$PA/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-a-story-created-2-lines" "2" "$LINES_A"
rm -rf "$PA"

# -----------------------------------------------------------------------------
# Case (b): sprint-kickoff emits 2 bus lines (original + auto-injected).
# -----------------------------------------------------------------------------
PB=$(mk_project)
CLAUDE_PROJECT_DIR="$PB" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"sprint-kickoff\",\"to\":\"*\",\"payload\":{\"manifest\":\"x\"}}" >/dev/null
LINES_B=$(wc -l < "$PB/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-b-sprint-kickoff-2-lines" "2" "$LINES_B"
rm -rf "$PB"

# -----------------------------------------------------------------------------
# Case (c): non-trigger type (story-done) emits 1 bus line — auto-inject is
# strictly type-gated.
# -----------------------------------------------------------------------------
PC=$(mk_project)
CLAUDE_PROJECT_DIR="$PC" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"story-done\",\"to\":\"*\"}" >/dev/null
LINES_C=$(wc -l < "$PC/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-c-story-done-1-line" "1" "$LINES_C"
rm -rf "$PC"

# -----------------------------------------------------------------------------
# Case (d): auto-injected envelope shape — type, to, from, payload.path,
# payload.reason.
# -----------------------------------------------------------------------------
PD=$(mk_project)
CLAUDE_PROJECT_DIR="$PD" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}" >/dev/null
INJECT_LINE=$(sed -n '2p' "$PD/implementations/.message-bus.jsonl")
INJECT_TYPE=$(echo "$INJECT_LINE" | jq -r '.type // empty')
INJECT_TO=$(echo "$INJECT_LINE" | jq -r '.to // empty')
INJECT_FROM=$(echo "$INJECT_LINE" | jq -r '.from // empty')
INJECT_PATH=$(echo "$INJECT_LINE" | jq -r '.payload.path // empty')
INJECT_REASON=$(echo "$INJECT_LINE" | jq -r '.payload.reason // empty')
assert_eq "case-d1-inject-type"   "read-token-discipline"          "$INJECT_TYPE"
assert_eq "case-d2-inject-to"     "*"                              "$INJECT_TO"
assert_eq "case-d3-inject-from"   "$SENDER"                        "$INJECT_FROM"
assert_eq "case-d4-inject-path"   "commands/_token-discipline.md"  "$INJECT_PATH"
assert_contains "case-d5-inject-reason-auto" "auto-injected" "$INJECT_REASON"
rm -rf "$PD"

# -----------------------------------------------------------------------------
# Case (e): single-write atomicity under concurrency — 5 parallel story-created
# calls produce exactly 10 lines AND every read-token-discipline line is
# immediately preceded by a story-created line (no interleaving).
# Single f.write(serialized + inject_serialized) <= PIPE_BUF (4096 bytes) is
# kernel-atomic on POSIX append-mode; concurrent writers' pairs never split.
# -----------------------------------------------------------------------------
PE=$(mk_project)
for i in 1 2 3 4 5; do
  CLAUDE_PROJECT_DIR="$PE" bash "$MCP_CALL" bus_emit \
    "{\"from\":\"$SENDER\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"r$i\"}}" >/dev/null &
done
wait
LINES_E=$(wc -l < "$PE/implementations/.message-bus.jsonl" | tr -d ' ')
# Walk the file: every read-token-discipline line MUST be immediately preceded
# by a story-created line. This proves the pair was a single contiguous write.
INTERLEAVED=0
PREV_TYPE=""
while IFS= read -r line; do
  this_type=$(echo "$line" | jq -r '.type // empty')
  if [ "$this_type" = "read-token-discipline" ]; then
    if [ "$PREV_TYPE" != "story-created" ]; then
      INTERLEAVED=$((INTERLEAVED+1))
    fi
  fi
  PREV_TYPE="$this_type"
done < "$PE/implementations/.message-bus.jsonl"
assert_eq "case-e-concurrent-5x-emits-10-lines" "10" "$LINES_E"
assert_eq "case-e-no-interleaving"               "0"  "$INTERLEAVED"
rm -rf "$PE"

# -----------------------------------------------------------------------------
# Doc-shape (f): _agent-protocol.md has a read-token-discipline row.
# -----------------------------------------------------------------------------
AGENT_PROTOCOL="$ROOT/commands/_agent-protocol.md"
assert_match "doc-f-protocol-has-row" "$AGENT_PROTOCOL" 'read-token-discipline'

# -----------------------------------------------------------------------------
# Doc-shape (h, amendment-4): all 5 role-startup files have ONE startup-read
# line for commands/_token-discipline.md. Per amendment-4 (mechanical-over-
# prose), this is the ENTIRE token-discipline footprint in role files — no
# Token-discipline section, no bus-handler bullets. The MCP server enforces
# the refresh in code; peers re-read on the auto-injected broadcast.
# (Startup blocks moved from commands/<role>.md to commands/_<role>-startup.md
# in v3.10.0; this test follows.)
# -----------------------------------------------------------------------------
for role in manager senior-developer pair-programmer tester slacker; do
  assert_match "doc-h-startup-${role}" "$ROOT/commands/_${role}-startup.md" 'commands/_token-discipline\.md'
done

# -----------------------------------------------------------------------------
# Doc-shape (i): NEGATIVE — _agent-protocol.md story-created schema does NOT
# contain token_discipline_doctrine. Amendment-1 removed the inline-payload
# field; this assertion guards the removal against future regression.
# -----------------------------------------------------------------------------
assert_no_match "doc-i-no-inline-payload-field" "$AGENT_PROTOCOL" 'token_discipline_doctrine'

# -----------------------------------------------------------------------------
# Case (j): pr-created auto-injects a code-review-request to pair-programmer-*,
# carrying the original pr-created payload (so PP has the PR number + url).
# -----------------------------------------------------------------------------
PJ=$(mk_project)
CLAUDE_PROJECT_DIR="$PJ" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"pr-created\",\"to\":\"manager-*\",\"payload\":{\"pr\":42,\"url\":\"http://x/42\"}}" >/dev/null
LINES_J=$(wc -l < "$PJ/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-j-pr-created-2-lines" "2" "$LINES_J"
CR_LINE=$(sed -n '2p' "$PJ/implementations/.message-bus.jsonl")
assert_eq "case-j-inject-type" "code-review-request" "$(echo "$CR_LINE" | jq -r '.type // empty')"
assert_eq "case-j-inject-to"   "pair-programmer-*"   "$(echo "$CR_LINE" | jq -r '.to // empty')"
assert_eq "case-j-inject-from" "$SENDER"             "$(echo "$CR_LINE" | jq -r '.from // empty')"
assert_eq "case-j-inject-pr"   "42"                  "$(echo "$CR_LINE" | jq -r '.payload.pr_created_payload.pr // empty')"
rm -rf "$PJ"

# Doc-shape (k): _agent-protocol.md has a code-review-request row.
assert_match "doc-k-protocol-has-cr-row" "$AGENT_PROTOCOL" 'code-review-request'

echo "mcp-server-bus-emit-auto-inject: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
