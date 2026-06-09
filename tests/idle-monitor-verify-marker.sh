#!/usr/bin/env bash
# Story 183 — idle-monitor respects a verify busy-marker (closes backlog-181).
# check_predicate counts the cohort BUSY when a live-PID .verify-running/<pid>.json
# marker exists (a run-all verify is in flight) — no time bound, fixing the
# >20-min verify that expired recent_bg_busy mid-run (the 238 false-idle). A
# dead-PID marker is ignored + swept. Drives idle-monitor.py --check-predicate
# against a temp fixture; WOW_IDLE_NOW_EPOCH pins "now" for deterministic aging.
#
# Cases:
#  c1 live-PID marker (cohort otherwise idle)        → busy
#  c2 dead-PID marker                                → idle + marker swept
#  c3 >20-min regression: stop + bg-spawn aged >1200s → idle WITHOUT marker, busy WITH a live marker
#  c4 no marker                                      → idle (marker never false-busies when absent)

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_eq() { local n="$1" e="$2" a="$3"
  if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected '$e', got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="$ROOT/scripts/wow-process/idle-monitor.py"
[ -f "$PY" ] || { echo "idle-monitor-verify-marker: SKIP — $PY not found"; exit 0; }

NOW=1780000000
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# alive + dead pids for the markers
sleep 300 & ALIVE=$!; disown "$ALIVE" 2>/dev/null || true
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null
cleanup() { kill "$ALIVE" 2>/dev/null; }
trap cleanup EXIT

# cohort = this test process ($$) as a live "manager" with a terminal stop row → idle baseline
mk_fixture() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  echo "manager" > "$d/.claude/.session-role-by-claude-pid/$$"
  printf '{"ts":"%s","claude_pid":%d,"role":"manager","type":"stop"}\n' "$(iso $((NOW-300)))" "$$" \
    > "$d/implementations/.activity.jsonl"
  echo "$d"
}
verify_marker() {  # $1=project $2=pid $3=heartbeat_iso
  mkdir -p "$1/implementations/.verify-running"
  printf '{"pid":%d,"role":"","started_ts":"%s","heartbeat_ts":"%s"}\n' "$2" "$3" "$3" \
    > "$1/implementations/.verify-running/$2.json"
}
predicate() { CLAUDE_PROJECT_DIR="$1" WOW_IDLE_NOW_EPOCH="$NOW" python3 "$PY" --check-predicate 2>/dev/null; }
marker_present() { [ -f "$1/implementations/.verify-running/$2.json" ] && echo yes || echo no; }

# c1: live-PID marker → busy (cohort is otherwise idle)
# RED-WITHOUT: patch .red-without/183-verify-marker-busy.patch -> c1-live-marker-busy
P=$(mk_fixture); verify_marker "$P" "$ALIVE" "$(iso $((NOW-60)))"
assert_eq "c1-live-marker-busy" "busy" "$(predicate "$P")"
rm -rf "$P"

# c2: dead-PID marker → idle + swept
P=$(mk_fixture); verify_marker "$P" "$DEAD" "$(iso $((NOW-60)))"
assert_eq "c2-dead-marker-idle" "idle" "$(predicate "$P")"
assert_eq "c2-dead-marker-swept" "no" "$(marker_present "$P" "$DEAD")"
rm -rf "$P"

# c3: >20-min regression — bg-spawn aged past 1200s (recent_bg_busy false) → idle WITHOUT marker; busy WITH a live marker
P=$(mk_fixture)
printf '{"ts":"%s","claude_pid":%d,"role":"manager","type":"bg-spawn"}\n{"ts":"%s","claude_pid":%d,"role":"manager","type":"stop"}\n' \
  "$(iso $((NOW-2000)))" "$$" "$(iso $((NOW-1900)))" "$$" > "$P/implementations/.activity.jsonl"
assert_eq "c3-without-marker-idle" "idle" "$(predicate "$P")"
verify_marker "$P" "$ALIVE" "$(iso $((NOW-60)))"
assert_eq "c3-regression-20min-busy" "busy" "$(predicate "$P")"
rm -rf "$P"

# c4: no marker → idle
P=$(mk_fixture)
assert_eq "c4-no-marker-idle" "idle" "$(predicate "$P")"
rm -rf "$P"

echo "idle-monitor-verify-marker: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
