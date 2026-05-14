#!/usr/bin/env bash
# Tests wow-remind-resume-work.sh — UserPromptSubmit hook that nudges M
# to call resume_work when .nothing_to_do is set.
#
# Cases:
# 1. M + marker present → emits additionalContext mentioning resume_work
# 2. M + marker absent → no stdout output, exit 0
# 3. Non-M role (senior-developer) + marker present → no stdout output
# 4. Role marker file missing → no stdout output, exit 0

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_eq() { local n="$1"; local e="$2"; local a="$3"
  if [ "$e" = "$a" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected '$e', got '$a')"); fi; }
assert_nonempty() { local n="$1"; local v="$2"
  if [ -n "$v" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected non-empty)"); fi; }
assert_empty() { local n="$1"; local v="$2"
  if [ -z "$v" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected empty, got '$v')"); fi; }
assert_contains() { local n="$1"; local hay="$2"; local needle="$3"
  case "$hay" in *"$needle"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected '$hay' to contain '$needle')") ;; esac; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/scripts/hooks/wow-remind-resume-work.sh"

mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo "$d"
}

STDIN_JSON='{"hook_event_name":"UserPromptSubmit","prompt":"hello"}'

# Case 1: M + marker present → emits additionalContext
P=$(mk_project)
echo "manager" > "$P/.claude/.session-role-by-claude-pid/$$"
echo '{"ts":"2026-05-14T10:00:00Z","declared_by":"manager","reason":null}' \
  > "$P/implementations/.nothing_to_do"
OF=$(mktemp); echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK" > "$OF"; OUT=$(cat "$OF"); rm -f "$OF"
EVENT=$(echo "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty')
CTX=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_eq "case-1-event-name" "UserPromptSubmit" "$EVENT"
assert_nonempty "case-1-additional-context" "$CTX"
assert_contains "case-1-mentions-resume-work" "$CTX" "resume_work"
rm -rf "$P"

# Case 2: M + marker absent → no output
P=$(mk_project)
echo "manager" > "$P/.claude/.session-role-by-claude-pid/$$"
OF=$(mktemp)
echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK" > "$OF"
RC=$?
OUT=$(cat "$OF"); rm -f "$OF"
assert_empty "case-2-no-output-without-marker" "$OUT"
assert_eq "case-2-exit-0" "0" "$RC"
rm -rf "$P"

# Case 3: Non-M (SD) + marker present → no output
P=$(mk_project)
echo "senior-developer" > "$P/.claude/.session-role-by-claude-pid/$$"
echo '{"ts":"2026-05-14T10:00:00Z","declared_by":"manager"}' \
  > "$P/implementations/.nothing_to_do"
OF=$(mktemp); echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK" > "$OF"; OUT=$(cat "$OF"); rm -f "$OF"
assert_empty "case-3-no-output-non-m" "$OUT"
rm -rf "$P"

# Case 4: Role marker missing → no output, exit 0
P=$(mk_project)
echo '{"ts":"2026-05-14T10:00:00Z","declared_by":"manager"}' \
  > "$P/implementations/.nothing_to_do"
OF=$(mktemp)
echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK" > "$OF"
RC=$?
OUT=$(cat "$OF"); rm -f "$OF"
assert_empty "case-4-no-output-no-role-marker" "$OUT"
assert_eq "case-4-exit-0" "0" "$RC"
rm -rf "$P"

echo
echo "wow-remind-resume-work: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
