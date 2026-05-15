#!/usr/bin/env bash
# plugin/tests/wow-inject-startup.sh
# Unit tests for the wow-inject-startup.sh UserPromptSubmit hook.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/hooks/wow-inject-startup.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

run_hook() {
  # Args: $1=PROMPT_BODY, $2=ROLE_TO_PROVISION_FILE (or "" for none)
  local prompt="$1"
  local provision_role="$2"
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/plugin/commands"
  if [ -n "$provision_role" ]; then
    echo "fake startup body" > "$tmpdir/plugin/commands/_${provision_role}-startup.md"
  fi
  CLAUDE_PROJECT_DIR="$tmpdir/project" CLAUDE_PLUGIN_ROOT="$tmpdir/plugin" \
    bash "$HOOK" <<EOF
{"hook_event_name":"UserPromptSubmit","prompt":$(jq -Rs . <<<"$prompt")}
EOF
  local ec=$?
  rm -rf "$tmpdir"
  return $ec
}

# Case 1: sentinel for manager + file present → emits additionalContext referencing _manager-startup.md
OUT=$(run_hook "<!-- claude-wow-startup: manager -->
You are the Manager." "manager" 2>&1)
if echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("_manager-startup\\.md")' >/dev/null 2>&1; then
  pass
else
  fail "case-1-manager-injection: stdout was '$OUT'"
fi

# Case 2: each of the other 4 roles
for role in senior-developer pair-programmer tester slacker; do
  OUT=$(run_hook "<!-- claude-wow-startup: $role -->
You are the $role." "$role" 2>&1)
  if echo "$OUT" | jq -e ".hookSpecificOutput.additionalContext | test(\"_${role}-startup\\\\.md\")" >/dev/null 2>&1; then
    pass
  else
    fail "case-2-${role}-injection: stdout was '$OUT'"
  fi
done

# Case 3: no sentinel → no output
OUT=$(run_hook "just a normal user prompt with no sentinel" "" 2>&1)
if [ -z "$OUT" ]; then pass; else fail "case-3-no-sentinel-output: stdout was '$OUT'"; fi

# Case 4: sentinel past line 5 → no output
OUT=$(run_hook "line1
line2
line3
line4
line5
<!-- claude-wow-startup: manager -->
line7" "manager" 2>&1)
if [ -z "$OUT" ]; then pass; else fail "case-4-sentinel-past-line5: stdout was '$OUT'"; fi

# Case 5: sentinel present but startup file absent → no output (graceful skip)
OUT=$(run_hook "<!-- claude-wow-startup: manager -->
body" "" 2>&1)
if [ -z "$OUT" ]; then pass; else fail "case-5-graceful-skip: stdout was '$OUT'"; fi

# Case 6: non-UserPromptSubmit event → no output
OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | bash "$HOOK" 2>&1)
if [ -z "$OUT" ]; then pass; else fail "case-6-wrong-event-type: stdout was '$OUT'"; fi

echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
