#!/usr/bin/env bash
# Confirms: marker present → main loop emits no nudge regardless of team state.
# Predicate function itself is pure (doesn't check marker), but main loop
# does the marker check BEFORE predicate eval.

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_eq() { local n="$1"; local e="$2"; local a="$3"
  if [ "$e" = "$a" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected '$e', got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MONITOR="$REPO_ROOT/scripts/wow-process/idle-monitor.py"

mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations" "$d/.claude-plugin"
  echo '{}' > "$d/.claude-plugin/plugin.json"
  echo "$d"
}

# Case 1: marker present + team idle → predicate still returns "idle" (pure)
P=$(mk_project)
echo "manager" > "$P/.claude/.session-role-by-claude-pid/$$"
echo '{"ts":"2026-05-14T10:00:00Z","claude_pid":'$$',"role":"manager","type":"stop","text":""}' \
  >> "$P/implementations/.activity.jsonl"
echo '{"ts":"2026-05-14T10:01:00Z","declared_by":"manager","reason":null}' \
  > "$P/implementations/.nothing_to_do"

OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-1-predicate-still-idle-with-marker" "idle" "$OUT"

# Case 2: invoke main loop briefly with marker present; verify no bus write
BUS="$P/implementations/.message-bus.jsonl"
touch "$BUS"
BUS_LINES_BEFORE=$(wc -l < "$BUS" | tr -d ' ')
CLAUDE_PROJECT_DIR="$P" timeout 3 python3 "$MONITOR" >/dev/null 2>&1 || true
BUS_LINES_AFTER=$(wc -l < "$BUS" | tr -d ' ')
assert_eq "case-2-no-bus-write-with-marker" "$BUS_LINES_BEFORE" "$BUS_LINES_AFTER"

rm -rf "$P"

echo
echo "monitor-marker-shortcircuit: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
