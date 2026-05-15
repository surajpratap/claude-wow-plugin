#!/usr/bin/env bash
# End-to-end: team idle + no marker → idle-monitor emits all-idle-nudge
# JSONL line on stdout (post-Story-076 transport; previously appended to
# the shared bus file).

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_eq() { local n="$1"; local e="$2"; local a="$3"
  if [ "$e" = "$a" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected '$e', got '$a')"); fi; }
assert_nonempty() { local n="$1"; local v="$2"
  if [ -n "$v" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected non-empty)"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MONITOR="$REPO_ROOT/scripts/wow-process/idle-monitor.py"

P=$(mktemp -d)
mkdir -p "$P/.claude/.session-role-by-claude-pid" "$P/implementations" "$P/.claude-plugin"
echo '{}' > "$P/.claude-plugin/plugin.json"
echo "manager" > "$P/.claude/.session-role-by-claude-pid/$$"
echo '{"ts":"2026-05-14T10:00:00Z","claude_pid":'$$',"role":"manager","type":"stop","text":"team is idle"}' \
  >> "$P/implementations/.activity.jsonl"

STDOUT_FILE=$(mktemp)
CLAUDE_PROJECT_DIR="$P" timeout 3 python3 "$MONITOR" > "$STDOUT_FILE" 2>/dev/null || true

LINES=$(wc -l < "$STDOUT_FILE" | tr -d ' ')
[ "$LINES" -ge 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("at-least-one-stdout-row"); }

ROW=$(tail -1 "$STDOUT_FILE")
TYPE=$(jq -r '.type' <<<"$ROW")
TO=$(jq -r '.to' <<<"$ROW")
FROM=$(jq -r '.from' <<<"$ROW")
PAYLOAD_AGENTS=$(jq -r '.payload.agents | length' <<<"$ROW")
PAYLOAD_PROMPT=$(jq -r '.payload.prompt // empty' <<<"$ROW")

assert_eq "type-all-idle-nudge" "all-idle-nudge" "$TYPE"
assert_eq "to-manager-glob" "manager-*" "$TO"
assert_nonempty "from-idle-monitor-agent-id" "$FROM"
assert_eq "payload-has-agents-array" "1" "$PAYLOAD_AGENTS"
assert_nonempty "payload-has-prompt" "$PAYLOAD_PROMPT"

# Critical: no bus appends from the new transport.
BUS="$P/implementations/.message-bus.jsonl"
BUS_LINES="0"
if [ -f "$BUS" ]; then
  BUS_LINES=$(wc -l < "$BUS" | tr -d ' ')
fi
assert_eq "no-bus-appends" "0" "$BUS_LINES"

rm -rf "$P" "$STDOUT_FILE"

echo
echo "monitor-nudge-bus-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
