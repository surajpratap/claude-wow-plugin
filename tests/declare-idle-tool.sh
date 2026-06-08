#!/usr/bin/env bash
# Tests declare_idle + resume_work MCP tools via stdio JSON-RPC.
#
# Story 181: declare_idle is now GATED — it refuses unless sd+pp+t are each
# confirmed truly-idle (i_am_truly_idle) + pid-alive + quiet. So cases that
# expect a marker first confirm all three via confirm_all (pid=$$, this test
# process, alive; the fixture has no .activity.jsonl so all read quiet).
#
# Cases:
# 1. declare_idle with no args → marker written, valid shape
# 2. declare_idle with reason → marker includes reason
# 3. declare_idle when marker already exists → overwrites with fresh ts (idempotent)
# 4. resume_work with marker present → marker deleted
# 5. resume_work when marker absent → no-op, success (idempotent)

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}
assert_nonempty() {
  local name="$1"; local val="$2"
  if [ -n "$val" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected non-empty)"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$REPO_ROOT/mcp/claude-wow-server/server.py"

mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/implementations" "$d/.claude-plugin"
  echo '{}' > "$d/.claude-plugin/plugin.json"
  echo "$d"
}

call_tool() {
  local proj="$1"; local tool="$2"; local args_json="$3"
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
  local call="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args_json}}"
  printf '%s\n%s\n' "$init" "$call" | CLAUDE_PROJECT_DIR="$proj" python3 "$SERVER" 2>/dev/null | tail -1
}

confirm_all() {
  # Story 181 — satisfy the declare_idle gate: confirm sd+pp+t truly-idle.
  local proj="$1"; local pid="$2"; local r
  for r in senior-developer pair-programmer tester; do
    call_tool "$proj" "i_am_truly_idle" "{\"role\":\"$r\",\"pid\":$pid}" > /dev/null
  done
}

# Case 1: declare_idle with no args → marker written, valid shape
P1=$(mk_project)
confirm_all "$P1" $$
RES=$(call_tool "$P1" "declare_idle" '{}')
MARKER="$P1/implementations/.nothing_to_do"
RC=$([ -f "$MARKER" ] && echo "present" || echo "missing")
assert_eq "case-1-declare-idle-marker-present" "present" "$RC"
DECLARED_BY=$(jq -r '.declared_by // empty' "$MARKER" 2>/dev/null)
assert_eq "case-1-declare-idle-declared-by" "manager" "$DECLARED_BY"
TS=$(jq -r '.ts // empty' "$MARKER" 2>/dev/null)
assert_nonempty "case-1-declare-idle-ts" "$TS"
rm -rf "$P1"

# Case 2: declare_idle with reason → marker includes reason
P2=$(mk_project)
confirm_all "$P2" $$
RES=$(call_tool "$P2" "declare_idle" '{"reason":"backlog empty"}')
MARKER="$P2/implementations/.nothing_to_do"
REASON=$(jq -r '.reason // empty' "$MARKER" 2>/dev/null)
assert_eq "case-2-declare-idle-reason" "backlog empty" "$REASON"
rm -rf "$P2"

# Case 3: idempotent overwrite — second call updates ts
P3=$(mk_project)
confirm_all "$P3" $$
call_tool "$P3" "declare_idle" '{"reason":"first"}' > /dev/null
MARKER="$P3/implementations/.nothing_to_do"
TS_FIRST=$(jq -r '.ts' "$MARKER")
sleep 1
call_tool "$P3" "declare_idle" '{"reason":"second"}' > /dev/null
TS_SECOND=$(jq -r '.ts' "$MARKER")
REASON_SECOND=$(jq -r '.reason' "$MARKER")
[ "$TS_FIRST" != "$TS_SECOND" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-3-idempotent-ts-updated"); }
assert_eq "case-3-idempotent-reason-updated" "second" "$REASON_SECOND"
rm -rf "$P3"

# Case 4: resume_work with marker present → marker deleted
P4=$(mk_project)
confirm_all "$P4" $$
call_tool "$P4" "declare_idle" '{}' > /dev/null
MARKER="$P4/implementations/.nothing_to_do"
[ -f "$MARKER" ] || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-4-precondition-marker-exists"); }
call_tool "$P4" "resume_work" '{}' > /dev/null
RC=$([ -f "$MARKER" ] && echo "present" || echo "missing")
assert_eq "case-4-resume-work-deletes-marker" "missing" "$RC"
rm -rf "$P4"

# Case 5: resume_work when marker absent → no-op, success
P5=$(mk_project)
RES=$(call_tool "$P5" "resume_work" '{}')
ERROR=$(echo "$RES" | jq -r '.error.message // empty' 2>/dev/null)
assert_eq "case-5-resume-work-no-marker-no-error" "" "$ERROR"
rm -rf "$P5"

echo
echo "declare-idle-tool: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
