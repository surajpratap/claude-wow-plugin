#!/usr/bin/env bash
# Tests dead PIDs are correctly excluded from the required set.

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_eq() { local n="$1"; local e="$2"; local a="$3"
  if [ "$e" = "$a" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected '$e', got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MONITOR="$REPO_ROOT/scripts/wow-process/manager-monitor.py"

mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations" "$d/.claude-plugin"
  echo '{}' > "$d/.claude-plugin/plugin.json"
  echo "$d"
}

DEAD_PID=99999
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID+1)); done

# Case 1: only dead PID → no-required-agents
P=$(mk_project)
echo "manager" > "$P/.claude/.session-role-by-claude-pid/$DEAD_PID"
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-1-only-dead-pid" "no-required-agents" "$OUT"
rm -rf "$P"

# Case 2: live M + dead SD → predicate evaluates on M only
P=$(mk_project)
echo "manager" > "$P/.claude/.session-role-by-claude-pid/$$"
echo "senior-developer" > "$P/.claude/.session-role-by-claude-pid/$DEAD_PID"
echo '{"ts":"2026-05-14T10:00:00Z","claude_pid":'$$',"role":"manager","type":"stop","text":""}' \
  >> "$P/implementations/.activity.jsonl"
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-2-dead-pid-ignored-idle" "idle" "$OUT"
rm -rf "$P"

echo
echo "monitor-pid-liveness: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
