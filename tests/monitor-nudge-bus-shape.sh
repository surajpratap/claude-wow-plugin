#!/usr/bin/env bash
# End-to-end: team idle + no marker → monitor emits all-idle-nudge bus row.

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
MONITOR="$REPO_ROOT/scripts/wow-process/manager-monitor.py"

P=$(mktemp -d)
mkdir -p "$P/.claude/.session-role-by-claude-pid" "$P/implementations" "$P/.claude-plugin"
echo '{}' > "$P/.claude-plugin/plugin.json"
echo "manager" > "$P/.claude/.session-role-by-claude-pid/$$"
echo '{"ts":"2026-05-14T10:00:00Z","claude_pid":'$$',"role":"manager","type":"stop","text":"team is idle"}' \
  >> "$P/implementations/.activity.jsonl"

CLAUDE_PROJECT_DIR="$P" timeout 3 python3 "$MONITOR" >/dev/null 2>&1 || true

BUS="$P/implementations/.message-bus.jsonl"
[ -f "$BUS" ] || { echo "bus file missing"; rm -rf "$P"; exit 1; }
LINES=$(wc -l < "$BUS" | tr -d ' ')
[ "$LINES" -ge 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("at-least-one-bus-row"); }

ROW=$(tail -1 "$BUS")
TYPE=$(jq -r '.type' <<<"$ROW")
TO=$(jq -r '.to' <<<"$ROW")
FROM=$(jq -r '.from' <<<"$ROW")
PAYLOAD_AGENTS=$(jq -r '.payload.agents | length' <<<"$ROW")
PAYLOAD_PROMPT=$(jq -r '.payload.prompt // empty' <<<"$ROW")

assert_eq "type-all-idle-nudge" "all-idle-nudge" "$TYPE"
assert_eq "to-manager-glob" "manager-*" "$TO"
assert_nonempty "from-monitor-agent-id" "$FROM"
assert_eq "payload-has-agents-array" "1" "$PAYLOAD_AGENTS"
assert_nonempty "payload-has-prompt" "$PAYLOAD_PROMPT"
rm -rf "$P"

echo
echo "monitor-nudge-bus-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
