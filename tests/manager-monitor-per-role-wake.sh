#!/usr/bin/env bash
# Story 111 — manager-monitor.py per-role truly-idle wake. Exercises
# emit_per_role_wakes() against fixture activity logs + .agents/ trackers.
#
# Cases:
#   (a) terminal+stale latest row for SD, no prior wake → emit a `wake`
#       to SD's agent_id; state file gets an entry.
#   (b) same setup but state file already has a recent entry (within
#       PER_ROLE_REWAKE_SECONDS) → NO wake emitted.
#   (c) non-terminal latest row → NO wake emitted.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANAGER_MONITOR="$ROOT/scripts/wow-process/manager-monitor.py"

if [ ! -f "$MANAGER_MONITOR" ]; then
  echo "manager-monitor-per-role-wake: SKIP — $MANAGER_MONITOR not found"
  exit 0
fi

mk_fixture() {
  local activity_type="$1"  # stop | stop_failure | prompt_in
  local age_seconds="$2"    # seconds ago for the row's ts
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/.claude/.session-role-by-claude-pid" \
    "$d/implementations" "$d/implementations/.agents" \
    "$d/implementations/.wow-process"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  local pid=$$
  echo "senior-developer" > "$d/.claude/.session-role-by-claude-pid/$pid"
  local now ts agent_id
  now=$(date -u +%s)
  ts=$((now - age_seconds))
  # macOS-friendly: `-r` accepts epoch.
  local iso_ts
  iso_ts=$(date -u -r "$ts" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
           || date -u -d "@$ts" +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","claude_pid":%s,"role":"senior-developer","type":"%s"}\n' \
    "$iso_ts" "$pid" "$activity_type" > "$d/implementations/.activity.jsonl"
  agent_id="senior-developer-20260518T120000-aabbcc"
  echo "{\"agent_id\":\"$agent_id\",\"claude_pid\":$pid,\"last_line\":42}" \
    > "$d/implementations/.agents/${agent_id}.json"
  echo "$d:$pid:$agent_id"
}

# Probe: call emit_per_role_wakes(<project_root>, live, now) via a one-line
# python that returns the count of wakes emitted + the first stdout line.
probe_emit() {
  local proj="$1"; local pid="$2"
  python3 -c "
import importlib.util, json, time, sys
spec = importlib.util.spec_from_file_location('manager_monitor', '$MANAGER_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
live = [('senior-developer', $pid)]
now = int(time.time())
fired = m.emit_per_role_wakes('$proj', live, now)
sys.stderr.write('fired:' + json.dumps(fired) + '\n')
" 2>"$proj/stderr.txt"
}

# ---- (a) terminal+stale → wake fires ----
PA_OUT=$(mk_fixture "stop" 700)  # PER_ROLE_IDLE_SECONDS=600, 700s ago is stale
PA_DIR=${PA_OUT%%:*}; rest=${PA_OUT#*:}; PA_PID=${rest%%:*}; PA_AGENT=${rest##*:}
WAKE_LINE_A=$(probe_emit "$PA_DIR" "$PA_PID")
FIRED_A=$(grep '^fired:' "$PA_DIR/stderr.txt" | sed 's/^fired://')
TYPE_A=$(echo "$WAKE_LINE_A" | jq -r '.type // empty')
TO_A=$(echo "$WAKE_LINE_A" | jq -r '.to // empty')
ROLE_A=$(echo "$WAKE_LINE_A" | jq -r '.payload.role // empty')
assert_eq "a-stale-terminal-emits-wake-type" "wake"            "$TYPE_A"
assert_eq "a-stale-terminal-wake-to-agent"   "$PA_AGENT"       "$TO_A"
assert_eq "a-stale-terminal-wake-role"       "senior-developer" "$ROLE_A"
assert_eq "a-state-file-records-agent"       "$PA_AGENT" \
  "$(jq -r 'keys[0] // empty' "$PA_DIR/implementations/.wow-process/manager-monitor-last-wake.json")"
rm -rf "$PA_DIR"

# ---- (b) state file has recent entry → noop ----
PB_OUT=$(mk_fixture "stop" 700)
PB_DIR=${PB_OUT%%:*}; rest=${PB_OUT#*:}; PB_PID=${rest%%:*}; PB_AGENT=${rest##*:}
RECENT_TS=$(date -u +%s)
echo "{\"$PB_AGENT\":$RECENT_TS}" \
  > "$PB_DIR/implementations/.wow-process/manager-monitor-last-wake.json"
WAKE_LINE_B=$(probe_emit "$PB_DIR" "$PB_PID")
assert_eq "b-recent-state-suppresses-wake" "" "$WAKE_LINE_B"
rm -rf "$PB_DIR"

# ---- (c) non-terminal latest row → noop ----
PC_OUT=$(mk_fixture "prompt_in" 700)
PC_DIR=${PC_OUT%%:*}; rest=${PC_OUT#*:}; PC_PID=${rest%%:*}
WAKE_LINE_C=$(probe_emit "$PC_DIR" "$PC_PID")
assert_eq "c-non-terminal-no-wake" "" "$WAKE_LINE_C"
rm -rf "$PC_DIR"

# ---- (d) state file rewake-window passed → wake fires again ----
PD_OUT=$(mk_fixture "stop" 700)
PD_DIR=${PD_OUT%%:*}; rest=${PD_OUT#*:}; PD_PID=${rest%%:*}; PD_AGENT=${rest##*:}
# 2000s > PER_ROLE_REWAKE_SECONDS (1800)
OLD_TS=$(( $(date -u +%s) - 2000 ))
echo "{\"$PD_AGENT\":$OLD_TS}" \
  > "$PD_DIR/implementations/.wow-process/manager-monitor-last-wake.json"
WAKE_LINE_D=$(probe_emit "$PD_DIR" "$PD_PID")
TYPE_D=$(echo "$WAKE_LINE_D" | jq -r '.type // empty')
assert_eq "d-rewake-window-passed-fires-again" "wake" "$TYPE_D"
rm -rf "$PD_DIR"

echo "manager-monitor-per-role-wake: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
