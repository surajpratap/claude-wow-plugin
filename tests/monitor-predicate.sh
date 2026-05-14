#!/usr/bin/env bash
# Tests manager-monitor.py's idle predicate function in isolation.
#
# Calls the python with --check-predicate flag that returns
# "idle" / "busy" / "no-required-agents" on stdout, rc 0.
#
# Cases:
# 1. All live PIDs' latest row is type:stop → "idle"
# 2. One PID's latest row is type:tool → "busy"
# 3. Mix of stop + stop_failure → "idle"
# 4. PID marker file present but PID dead (kill -0 fails) → that role excluded
# 5. No live PIDs at all → "no-required-agents"
# 6. Slacker present but slacker not in required set → ignored

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_eq() { local name="$1"; local exp="$2"; local act="$3"
  if [ "$exp" = "$act" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$exp', got '$act')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MONITOR="$REPO_ROOT/scripts/wow-process/manager-monitor.py"

mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations" "$d/.claude-plugin"
  echo '{}' > "$d/.claude-plugin/plugin.json"
  echo "$d"
}

write_row() {
  local proj="$1"; local role="$2"; local pid="$3"; local type="$4"; local extra="${5:-}"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local row
  if [ -n "$extra" ]; then
    row=$(jq -cn --arg ts "$ts" --argjson pid "$pid" --arg role "$role" --arg type "$type" --argjson extra "$extra" \
      '{ts:$ts, claude_pid:$pid, role:$role, type:$type} + $extra')
  else
    row=$(jq -cn --arg ts "$ts" --argjson pid "$pid" --arg role "$role" --arg type "$type" \
      '{ts:$ts, claude_pid:$pid, role:$role, type:$type}')
  fi
  echo "$row" >> "$proj/implementations/.activity.jsonl"
}

register_pid() {
  local proj="$1"; local role="$2"; local pid="$3"
  echo "$role" > "$proj/.claude/.session-role-by-claude-pid/$pid"
}

# Case 1: all required PIDs' latest row is stop → idle
P=$(mk_project)
register_pid "$P" "manager" "$$"
register_pid "$P" "senior-developer" "$$"
write_row "$P" "manager" "$$" "stop" '{"text":"idle"}'
write_row "$P" "senior-developer" "$$" "stop" '{"text":"idle"}'
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-1-all-stop-idle" "idle" "$OUT"
rm -rf "$P"

# Case 2: one PID's latest row is tool → busy
P=$(mk_project)
register_pid "$P" "manager" "$$"
register_pid "$P" "senior-developer" "$$"
write_row "$P" "manager" "$$" "stop" '{"text":"idle"}'
write_row "$P" "senior-developer" "$$" "tool" '{"tool":"Bash"}'
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-2-one-busy" "busy" "$OUT"
rm -rf "$P"

# Case 3: mix of stop + stop_failure → idle
P=$(mk_project)
register_pid "$P" "manager" "$$"
register_pid "$P" "senior-developer" "$$"
write_row "$P" "manager" "$$" "stop" '{"text":""}'
write_row "$P" "senior-developer" "$$" "stop_failure"
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-3-mix-stop-failure-idle" "idle" "$OUT"
rm -rf "$P"

# Case 4: PID marker present but PID dead → that role excluded
P=$(mk_project)
DEAD_PID=99999
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID+1)); done
register_pid "$P" "manager" "$$"
register_pid "$P" "senior-developer" "$DEAD_PID"
write_row "$P" "manager" "$$" "stop" '{"text":""}'
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-4-dead-pid-excluded-idle" "idle" "$OUT"
rm -rf "$P"

# Case 5: no live PIDs at all → no-required-agents
P=$(mk_project)
DEAD_PID=99999
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID+1)); done
register_pid "$P" "manager" "$DEAD_PID"
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-5-no-live-pids" "no-required-agents" "$OUT"
rm -rf "$P"

# Case 6: Slacker present (live) but excluded from required set
# Use PPID for slacker so the two marker files don't collide (last write wins).
P=$(mk_project)
register_pid "$P" "manager" "$$"
register_pid "$P" "slacker" "$PPID"
write_row "$P" "manager" "$$" "stop" '{"text":""}'
write_row "$P" "slacker" "$PPID" "tool" '{"tool":"Read"}'
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$MONITOR" --check-predicate)
assert_eq "case-6-slacker-ignored" "idle" "$OUT"
rm -rf "$P"

echo
echo "monitor-predicate: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
