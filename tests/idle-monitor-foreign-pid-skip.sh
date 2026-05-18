#!/usr/bin/env bash
# Story 110 — idle-monitor's check_predicate skips foreign/stale-marker PIDs
# (live PIDs with project-local role markers but ZERO rows in .activity.jsonl).
# Without the fix, a foreign PID poisons the predicate to "busy" forever and
# kills the all-idle nudge.

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
IDLE_MONITOR="$ROOT/scripts/wow-process/idle-monitor.py"

# Probe: call check_predicate(<project_root>) via a one-line python.
predicate() {
  local proj="$1"
  python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('idle_monitor', '$IDLE_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.check_predicate('$proj'))
"
}

# Fixture: a project_root with .claude/.session-role-by-claude-pid/<pid> markers
# for two PIDs; .activity.jsonl seeded per case. Each marker file contains a
# role name (per idle-monitor.py's live_required_pids reader).
mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo "$d"
}

# Use SELF PID for "alive" check (kill -0 self always succeeds).
PID_A="$$"
# Use another live PID — the parent shell PID, also alive.
PID_B="$PPID"
# Make sure they differ; if PID_A == PID_B, use PID_A+1 with a hope-it-lives caveat.
if [ "$PID_A" = "$PID_B" ]; then
  PID_B=$((PID_A + 1))
fi

# ---- Case (a): one PID has rows ending in `stop`, other has no rows → idle ----
PA=$(mk_project)
# Mark both PIDs as 'manager' (in REQUIRED_ROLES).
echo "manager" > "$PA/.claude/.session-role-by-claude-pid/$PID_A"
echo "manager" > "$PA/.claude/.session-role-by-claude-pid/$PID_B"
# PID_A: one session_start + one stop.
printf '{"ts":"2026-05-18T12:00:00Z","claude_pid":%s,"role":"manager","type":"session_start"}\n' "$PID_A" > "$PA/implementations/.activity.jsonl"
printf '{"ts":"2026-05-18T12:00:30Z","claude_pid":%s,"role":"manager","type":"stop"}\n'          "$PID_A" >> "$PA/implementations/.activity.jsonl"
# PID_B: no rows. Foreign/stale marker.
OUT_A=$(predicate "$PA")
assert_eq "a-foreign-PID-skipped-yields-idle" "idle" "$OUT_A"
rm -rf "$PA"

# ---- Case (b): only the foreign PID → no-required-agents ----
PB=$(mk_project)
echo "manager" > "$PB/.claude/.session-role-by-claude-pid/$PID_B"
# .activity.jsonl is empty (no rows at all).
touch "$PB/implementations/.activity.jsonl"
OUT_B=$(predicate "$PB")
assert_eq "b-all-foreign-yields-no-required-agents" "no-required-agents" "$OUT_B"
rm -rf "$PB"

# ---- Case (c): PID_A has rows ending in prompt_in (non-terminal) → busy ----
PC=$(mk_project)
echo "manager" > "$PC/.claude/.session-role-by-claude-pid/$PID_A"
echo "manager" > "$PC/.claude/.session-role-by-claude-pid/$PID_B"
printf '{"ts":"2026-05-18T12:00:00Z","claude_pid":%s,"role":"manager","type":"session_start"}\n' "$PID_A" > "$PC/implementations/.activity.jsonl"
printf '{"ts":"2026-05-18T12:00:30Z","claude_pid":%s,"role":"manager","type":"prompt_in"}\n'      "$PID_A" >> "$PC/implementations/.activity.jsonl"
OUT_C=$(predicate "$PC")
assert_eq "c-real-busy-preserved" "busy" "$OUT_C"
rm -rf "$PC"

# ---- Case (d): mechanical assertion — idle-monitor.py has the `continue` branch ----
if grep -qF "if not rows:" "$IDLE_MONITOR" && \
   grep -A8 "if not rows:" "$IDLE_MONITOR" | grep -qF "continue"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("d-mechanical-continue-branch (missing 'if not rows: continue' in idle-monitor.py)")
fi

# ---- Case (e) — Story 129: gather_agent_summary drops no-rows PIDs ----
# Two-PID fixture: PID_A has stop rows, PID_B is foreign no-rows. The
# all-idle-nudge payload's agents[] must contain ONLY PID_A — no ghost
# entry for PID_B with empty last_type / last_text.
PE=$(mktemp -d)
mkdir -p "$PE/.claude/.session-role-by-claude-pid" "$PE/implementations"
echo "manager" > "$PE/.claude/.session-role-by-claude-pid/$PID_A"
echo "senior-developer" > "$PE/.claude/.session-role-by-claude-pid/$PID_B"
printf '{"ts":"2026-05-18T12:00:00Z","claude_pid":%s,"role":"manager","type":"session_start"}\n' "$PID_A" > "$PE/implementations/.activity.jsonl"
printf '{"ts":"2026-05-18T12:00:30Z","claude_pid":%s,"role":"manager","type":"stop","text":"all done"}\n' "$PID_A" >> "$PE/implementations/.activity.jsonl"
# PID_B has no rows — foreign/stale.
SUMMARY_LEN=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('idle_monitor', '$IDLE_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
live = m.live_required_pids('$PE')
agents = m.gather_agent_summary('$PE', live)
print(len(agents))
print(agents[0]['claude_pid'] if agents else 'none')
" 2>&1)
ACTUAL_LEN=$(echo "$SUMMARY_LEN" | sed -n '1p')
ACTUAL_PID=$(echo "$SUMMARY_LEN" | sed -n '2p')
assert_eq "e-gather-skips-no-rows-yields-1-agent"     "1"      "$ACTUAL_LEN"
assert_eq "e-gather-skips-no-rows-surviving-pid"      "$PID_A" "$ACTUAL_PID"
rm -rf "$PE"

echo "idle-monitor-foreign-pid-skip: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
