#!/usr/bin/env bash
# Story 186 — manager-monitor's `usage_concern()` PIPES a usage signal to M on
# STDOUT (the Monitor->M channel), instead of emitting bus pause/resume/escalate
# directives itself. M owns the reaction (urgent pause + kill_subagents / resume
# / human escalation). This test drives the real `usage_concern(project_root)`
# against a fixture usage-state file + injectable clock (WOW_IDLE_NOW_EPOCH) and
# asserts the piped STDOUT lines — and that NOTHING is written to the bus.
#
# Cases:
#   (a) 5h>=95, no marker → exactly ONE `usage-limit` line on STDOUT (window
#       five_hour, used_percentage, resets_at); a pause-marker is written. None
#       at 94.
#   (b) idempotent: a second tick while the marker is active pipes NO second
#       usage-limit.
#   (c) 5h time-resume: marker active + now>=resets_at+buffer → ONE `usage-reset`
#       on STDOUT; marker cleared. NOT before reset.
#   (d) 7d>=99 → exactly ONE `usage-escalate` on STDOUT (window seven_day) and NO
#       `usage-limit` (peers are NOT auto-paused on 7d). None at 98.
#   (e) the piped `from` carries the `manager-monitor-` prefix.
#   (f) PIPED-TO-M-NOT-BUS: the daemon writes the signal to STDOUT and leaves the
#       message bus untouched (no bus file / no directive on it).
#   (g) runs even with .nothing_to_do present (outside the idle guard).
#
# RED-WITHOUT: patch .red-without/186-threshold-9598.patch -> a-5h-95-emits-one-limit
# RED-WITHOUT: patch .red-without/186-usage-direct-bus.patch -> f-piped-to-stdout-not-bus
# RED-WITHOUT: patch .red-without/186-usage-time-resume.patch -> c-no-resume-before-reset
# RED-WITHOUT: patch .red-without/186-usage-idempotency.patch -> b-idempotent-still-one-limit
# RED-WITHOUT: patch .red-without/186-usage-7d-escalate.patch -> d-7d-emits-one-escalate

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
  echo "manager-monitor-usage-limit: SKIP — $MANAGER_MONITOR not found"
  exit 0
fi
if ! python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('manager_monitor','$MANAGER_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import sys; sys.exit(0 if hasattr(m,'usage_concern') else 1)
" 2>/dev/null; then
  echo "manager-monitor-usage-limit: SKIP — usage_concern not present yet"
  exit 0
fi

# mk_fixture <five_pct> <seven_pct> <five_resets_at_iso>
mk_fixture() {
  local five="$1" seven="$2" resets="$3" d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations/.wow-process"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  cat > "$d/implementations/.wow-process/five-hour-usage.json" <<JSON
{"five_hour":{"used_percentage":$five,"resets_at":"$resets"},"seven_day":{"used_percentage":$seven,"resets_at":"2026-06-05T00:00:00Z"},"captured_ts":1}
JSON
  echo "$d"
}

# Run usage_concern(project_root); the piped signal goes to STDOUT (captured to
# $proj/stdout.txt). The bus is NOT written by the daemon (M owns the reaction).
run_check() {
  local proj="$1" now_epoch="$2"
  ( cd "$proj" && \
    CLAUDE_PROJECT_DIR="$proj" WOW_ROOT="$proj" WOW_IDLE_NOW_EPOCH="$now_epoch" \
    WOW_USAGE_AUTOPAUSE=1 \
    python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('manager_monitor','$MANAGER_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.usage_concern('$proj')
" > "$proj/stdout.txt" 2> "$proj/stderr.txt" )
}

bus_path() { echo "$1/implementations/.message-bus.jsonl"; }
marker_path() { echo "$1/implementations/.wow-process/usage-limit-pause-marker.json"; }

# Emit each stdout JSON event whose .type == $2 as compact JSON (spacing-robust).
events_of_type() {
  local proj="$1" type="$2"
  [ -f "$proj/stdout.txt" ] || return 0
  jq -c --arg t "$type" 'select(.type==$t)' "$proj/stdout.txt" 2>/dev/null
}
# count piped events of a given type on stdout.txt (0 on missing/none).
count_type() {
  local n
  n=$(events_of_type "$1" "$2" | grep -c .)
  echo "${n:-0}"
}

RESETS_ISO="2026-05-31T12:00:00Z"
RESETS_EPOCH=$(python3 -c "import datetime;print(int(datetime.datetime.fromisoformat('2026-05-31T12:00:00+00:00').timestamp()))")
BEFORE_RESET=$((RESETS_EPOCH - 600))
AFTER_RESET=$((RESETS_EPOCH + 600))

# ================= (a) 5h>=95 → one usage-limit on stdout; none below =========
PA=$(mk_fixture 95 10 "$RESETS_ISO")
run_check "$PA" "$BEFORE_RESET"
assert_eq "a-5h-95-emits-one-limit" "1" "$(count_type "$PA" usage-limit)"
LINE_A=$(events_of_type "$PA" usage-limit | head -1)
assert_eq "a-limit-window"        "five_hour"   "$(echo "$LINE_A" | jq -r '.payload.window')"
assert_eq "a-limit-kind"          "usage-limit" "$(echo "$LINE_A" | jq -r '.payload.kind')"
assert_eq "a-limit-used-pct"      "95"          "$(echo "$LINE_A" | jq -r '.payload.used_percentage')"
assert_eq "a-limit-carries-resets" "$RESETS_ISO" "$(echo "$LINE_A" | jq -r '.payload.resets_at')"
assert_eq "a-marker-written"      "present"     "$([ -e "$(marker_path "$PA")" ] && echo present || echo absent)"
# (e) from-prefix manager-monitor-
FROM_A=$(echo "$LINE_A" | jq -r '.from')
case "$FROM_A" in
  manager-monitor-*) assert_eq "e-from-manager-monitor-prefix" "yes" "yes" ;;
  *)                 assert_eq "e-from-manager-monitor-prefix" "yes" "no ($FROM_A)" ;;
esac
# (f) PIPED-TO-M-NOT-BUS: stdout carries the signal AND the bus is untouched.
assert_eq "f-piped-to-stdout-not-bus" "stdout-only" \
  "$([ -s "$PA/stdout.txt" ] && [ ! -s "$(bus_path "$PA")" ] && echo stdout-only || echo bus-touched)"

# below threshold → none
PA0=$(mk_fixture 94 10 "$RESETS_ISO")
run_check "$PA0" "$BEFORE_RESET"
assert_eq "a-5h-94-no-limit" "0" "$(count_type "$PA0" usage-limit)"
rm -rf "$PA0"

# ================= (b) idempotent: second tick → no 2nd usage-limit ==========
run_check "$PA" "$BEFORE_RESET"
assert_eq "b-idempotent-still-one-limit" "0" "$(count_type "$PA" usage-limit)"
rm -rf "$PA"

# ================= (g) runs with .nothing_to_do present =================
PG=$(mk_fixture 95 10 "$RESETS_ISO")
: > "$PG/implementations/.nothing_to_do"
run_check "$PG" "$BEFORE_RESET"
assert_eq "g-runs-with-nothing-to-do" "1" "$(count_type "$PG" usage-limit)"
rm -rf "$PG"

# ================= (c) time-resume: not before; fires at/after reset ========
# Self-contained: tick 1 (before reset) does pause-detect → writes the marker
# FILE; tick 2 (still before reset) enters WITH the marker present → the time
# gate must suppress the resume (the 186-usage-time-resume revert drops that gate
# → resume fires before reset → c-no-resume-before-reset flips RED).
PC=$(mk_fixture 95 10 "$RESETS_ISO")
run_check "$PC" "$BEFORE_RESET"   # establishes the marker file
run_check "$PC" "$BEFORE_RESET"   # marker present + before reset → no resume
assert_eq "c-no-resume-before-reset" "0" "$(count_type "$PC" usage-reset)"
# Tick AFTER reset → exactly one usage-reset, marker cleared.
run_check "$PC" "$AFTER_RESET"
assert_eq "c-resume-after-reset" "1" "$(count_type "$PC" usage-reset)"
LINE_C=$(events_of_type "$PC" usage-reset | head -1)
assert_eq "c-reset-kind"   "usage-reset" "$(echo "$LINE_C" | jq -r '.payload.kind')"
assert_eq "c-reset-window" "five_hour"   "$(echo "$LINE_C" | jq -r '.payload.window')"
assert_eq "c-marker-cleared" "absent" "$([ -e "$(marker_path "$PC")" ] && echo present || echo absent)"
rm -rf "$PC"

# ===== (d) 7d>=99 → ONE usage-escalate on stdout (seven_day), NO usage-limit =====
PD=$(mk_fixture 50 99 "$RESETS_ISO")
run_check "$PD" "$BEFORE_RESET"
assert_eq "d-7d-no-peer-limit" "0" "$(count_type "$PD" usage-limit)"
assert_eq "d-7d-emits-one-escalate" "1" "$(count_type "$PD" usage-escalate)"
LINE_D=$(events_of_type "$PD" usage-escalate | head -1)
assert_eq "d-escalate-window" "seven_day" "$(echo "$LINE_D" | jq -r '.payload.window')"
assert_eq "d-escalate-kind"   "usage-escalate" "$(echo "$LINE_D" | jq -r '.payload.kind')"
FROM_D=$(echo "$LINE_D" | jq -r '.from')
case "$FROM_D" in
  manager-monitor-*) assert_eq "d-escalate-from-prefix" "yes" "yes" ;;
  *)                 assert_eq "d-escalate-from-prefix" "yes" "no ($FROM_D)" ;;
esac
# 7d below threshold → no escalate.
PD0=$(mk_fixture 50 98 "$RESETS_ISO")
run_check "$PD0" "$BEFORE_RESET"
assert_eq "d-7d-98-no-escalate" "0" "$(count_type "$PD0" usage-escalate)"
rm -rf "$PD0"
rm -rf "$PD"

echo "manager-monitor-usage-limit: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
