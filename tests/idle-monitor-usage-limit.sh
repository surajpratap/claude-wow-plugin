#!/usr/bin/env bash
# Story 172 — idle-limit-monitor's additive `_check_usage_limits()` codepath.
#
# Behavioral. Drives the real `_check_usage_limits(project_root)` against a
# fixture usage-state file + injectable clock (WOW_IDLE_NOW_EPOCH) + an
# INJECTED fixture bus (CLAUDE_PROJECT_DIR/WOW_ROOT = $fixture, so the sanctioned
# `bus_emit` subprocess resolves to the FIXTURE bus, NEVER the real one — 174
# discipline / MAJOR-1).
#
# Cases:
#   (a) 5h>=98, no marker → exactly ONE usage-limit-pause to:* directive:pause
#       on the FIXTURE bus; a pause-marker is written. None emitted below 98.
#   (b) idempotent: a second tick while the marker is active emits NO second pause.
#   (c) 5h time-resume: marker active + now>=resets_at+buffer → ONE
#       usage-limit-reset to:* directive:resume; marker cleared. NOT before reset.
#   (d) 7d>=99 → exactly ONE M-PRIVATE bus directive (to: manager-*,
#       payload.directive == "escalate", window seven_day) on the FIXTURE bus,
#       and NO to:* pause line (peers NOT auto-halted on 7d, #140). FINDING-47:
#       the escalate is a BUS directive M routes+acts on, not an off-bus print().
#   (e) the emitted `from` matches AGENT_ID_RE (limit-monitor- prefix, lowercase hex).
#   (f) MAJOR-1: the emit landed on the FIXTURE bus (asserted by reading $fixture's
#       bus, never the real one) — the bus_emit subprocess inherited the env.
#   (g) runs even with .nothing_to_do present (outside the idle guard).
#
# RED-WITHOUT: patch .red-without/usage-limit-5h-threshold.patch -> a-5h-98-emits-one-pause
# RED-WITHOUT: patch .red-without/usage-limit-time-resume.patch -> c-no-resume-before-reset
# RED-WITHOUT: patch .red-without/usage-limit-idempotency.patch -> b-idempotent-still-one-pause
# RED-WITHOUT: patch .red-without/usage-limit-7d-escalate.patch -> d-7d-emits-one-escalate

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

if [ ! -f "$IDLE_MONITOR" ]; then
  echo "idle-monitor-usage-limit: SKIP — $IDLE_MONITOR not found"
  exit 0
fi
if ! python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('idle_monitor','$IDLE_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import sys; sys.exit(0 if hasattr(m,'_check_usage_limits') else 1)
" 2>/dev/null; then
  echo "idle-monitor-usage-limit: SKIP — _check_usage_limits not present yet"
  exit 0
fi

AGENT_ID_RE='^[a-z-]+-[0-9]{8}T[0-9]{6}-[a-f0-9]{6}$'

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

# Run _check_usage_limits(project_root) with the fixture as the resolved root.
# Any daemon stdout/stderr is captured to $proj/stdout.txt / stderr.txt; the
# directives (5h pause/resume + 7d escalate) land on the bus, which resolves to
# $proj/implementations/.message-bus.jsonl (CLAUDE_PROJECT_DIR+WOW_ROOT).
run_check() {
  local proj="$1" now_epoch="$2"
  ( cd "$proj" && \
    CLAUDE_PROJECT_DIR="$proj" WOW_ROOT="$proj" WOW_IDLE_NOW_EPOCH="$now_epoch" \
    WOW_USAGE_AUTOPAUSE=1 \
    python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('idle_monitor','$IDLE_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._check_usage_limits('$proj')
" > "$proj/stdout.txt" 2> "$proj/stderr.txt" )
}

bus_path() { echo "$1/implementations/.message-bus.jsonl"; }
marker_path() { echo "$1/implementations/.wow-process/usage-limit-pause-marker.json"; }

# count_lines <file> <fixed-pattern> — robust integer (0 on missing file / no
# match; grep -c returns rc 1 on zero, so we must not let `||` append a digit).
count_lines() {
  local f="$1" pat="$2" n
  [ -f "$f" ] || { echo 0; return; }
  n=$(grep -cF -- "$pat" "$f" 2>/dev/null)
  echo "${n:-0}"
}

# epoch for a fixed resets_at (well in the past so resume can fire when asked)
RESETS_ISO="2026-05-31T12:00:00Z"
RESETS_EPOCH=$(python3 -c "import datetime;print(int(datetime.datetime.fromisoformat('2026-05-31T12:00:00+00:00').timestamp()))")
BEFORE_RESET=$((RESETS_EPOCH - 600))
AFTER_RESET=$((RESETS_EPOCH + 600))

# ================= (a) 5h>=98 → one pause; none below =================
PA=$(mk_fixture 98 10 "$RESETS_ISO")
run_check "$PA" "$BEFORE_RESET"
BUS_A=$(bus_path "$PA")
N_PAUSE_A=$(count_lines "$BUS_A" '"type":"usage-limit-pause"')
assert_eq "a-5h-98-emits-one-pause" "1" "$N_PAUSE_A"
LINE_A=$(grep '"type":"usage-limit-pause"' "$BUS_A" 2>/dev/null | head -1)
assert_eq "a-pause-to-broadcast"   "*"          "$(echo "$LINE_A" | jq -r '.to')"
assert_eq "a-pause-directive"      "pause"      "$(echo "$LINE_A" | jq -r '.payload.directive')"
assert_eq "a-pause-window"         "five_hour"  "$(echo "$LINE_A" | jq -r '.payload.window')"
assert_eq "a-pause-carries-resets" "$RESETS_ISO" "$(echo "$LINE_A" | jq -r '.payload.resets_at')"
assert_eq "a-marker-written"       "present"    "$([ -e "$(marker_path "$PA")" ] && echo present || echo absent)"
# (e) from-ID shape
FROM_A=$(echo "$LINE_A" | jq -r '.from')
if echo "$FROM_A" | grep -Eq "$AGENT_ID_RE"; then
  assert_eq "e-from-matches-AGENT_ID_RE" "yes" "yes"
else
  assert_eq "e-from-matches-AGENT_ID_RE" "yes" "no ($FROM_A)"
fi
case "$FROM_A" in
  limit-monitor-*) assert_eq "e-from-limit-monitor-prefix" "yes" "yes" ;;
  *)               assert_eq "e-from-limit-monitor-prefix" "yes" "no ($FROM_A)" ;;
esac
# (f) MAJOR-1: emit landed on the FIXTURE bus (the file exists under $PA), and
# the real bus was untouched (it is outside $PA). The bus path resolved to the
# fixture proves the bus_emit subprocess inherited CLAUDE_PROJECT_DIR/WOW_ROOT.
assert_eq "f-emit-on-fixture-bus" "present" "$([ -s "$BUS_A" ] && echo present || echo absent)"

# below threshold → none
PA0=$(mk_fixture 97 10 "$RESETS_ISO")
run_check "$PA0" "$BEFORE_RESET"
N_PAUSE_A0=$(count_lines "$(bus_path "$PA0")" '"type":"usage-limit-pause"')
assert_eq "a-5h-97-no-pause" "0" "$N_PAUSE_A0"
rm -rf "$PA0"

# ================= (b) idempotent: second tick → no 2nd pause =================
run_check "$PA" "$BEFORE_RESET"
N_PAUSE_B=$(count_lines "$BUS_A" '"type":"usage-limit-pause"')
assert_eq "b-idempotent-still-one-pause" "1" "$N_PAUSE_B"

# ================= (g) runs with .nothing_to_do present =================
PG=$(mk_fixture 98 10 "$RESETS_ISO")
: > "$PG/implementations/.nothing_to_do"
run_check "$PG" "$BEFORE_RESET"
N_PAUSE_G=$(count_lines "$(bus_path "$PG")" '"type":"usage-limit-pause"')
assert_eq "g-runs-with-nothing-to-do" "1" "$N_PAUSE_G"
rm -rf "$PG"

# ================= (c) time-resume: not before; fires at/after reset =================
# Reuse $PA (marker active from case a). Tick BEFORE reset → no resume.
run_check "$PA" "$BEFORE_RESET"
N_RESUME_BEFORE=$(count_lines "$BUS_A" '"type":"usage-limit-reset"')
assert_eq "c-no-resume-before-reset" "0" "$N_RESUME_BEFORE"
# Tick AFTER reset → exactly one resume, marker cleared.
run_check "$PA" "$AFTER_RESET"
N_RESUME_AFTER=$(count_lines "$BUS_A" '"type":"usage-limit-reset"')
assert_eq "c-resume-after-reset" "1" "$N_RESUME_AFTER"
LINE_C=$(grep '"type":"usage-limit-reset"' "$BUS_A" 2>/dev/null | head -1)
assert_eq "c-resume-directive" "resume" "$(echo "$LINE_C" | jq -r '.payload.directive')"
assert_eq "c-resume-to-broadcast" "*" "$(echo "$LINE_C" | jq -r '.to')"
FROM_C=$(echo "$LINE_C" | jq -r '.from')
if echo "$FROM_C" | grep -Eq "$AGENT_ID_RE"; then
  assert_eq "c-resume-from-matches-AGENT_ID_RE" "yes" "yes"
else
  assert_eq "c-resume-from-matches-AGENT_ID_RE" "yes" "no ($FROM_C)"
fi
assert_eq "c-marker-cleared" "absent" "$([ -e "$(marker_path "$PA")" ] && echo present || echo absent)"
rm -rf "$PA"

# ===== (d) 7d>=99 → ONE M-private BUS escalate directive (to: manager-*), NO peer pause =====
# FINDING-47: the 7d escalate is a BUS directive (payload.directive:escalate,
# to: manager-*) M routes+acts on — NOT an off-bus stdout print() that fell
# through M's dispatch inert. Peers are NOT auto-halted on 7d (#140): no pause.
PD=$(mk_fixture 50 99 "$RESETS_ISO")
run_check "$PD" "$BEFORE_RESET"
BUS_D=$(bus_path "$PD")
# NO 5h pause directive (peers not auto-halted on 7d).
N_PAUSE_D=$(count_lines "$BUS_D" '"type":"usage-limit-pause"')
assert_eq "d-7d-no-peer-pause" "0" "$N_PAUSE_D"
# Exactly ONE escalate directive landed on the FIXTURE bus.
N_ESC_D=$(count_lines "$BUS_D" '"type":"usage-limit-7d-escalate"')
assert_eq "d-7d-emits-one-escalate" "1" "$N_ESC_D"
LINE_D=$(grep '"type":"usage-limit-7d-escalate"' "$BUS_D" 2>/dev/null | head -1)
assert_eq "d-escalate-to-manager"  "manager-*" "$(echo "$LINE_D" | jq -r '.to')"
assert_eq "d-escalate-directive"   "escalate"  "$(echo "$LINE_D" | jq -r '.payload.directive')"
assert_eq "d-escalate-window"      "seven_day" "$(echo "$LINE_D" | jq -r '.payload.window')"
# from-ID shape: AGENT_ID_RE + limit-monitor- prefix (NOT idle-monitor-, which M
# would misclassify as a private idle-event — BLOCKER-1 / FINDING-47 routing).
FROM_D=$(echo "$LINE_D" | jq -r '.from')
if echo "$FROM_D" | grep -Eq "$AGENT_ID_RE"; then
  assert_eq "d-escalate-from-matches-AGENT_ID_RE" "yes" "yes"
else
  assert_eq "d-escalate-from-matches-AGENT_ID_RE" "yes" "no ($FROM_D)"
fi
case "$FROM_D" in
  limit-monitor-*) assert_eq "d-escalate-from-limit-monitor-prefix" "yes" "yes" ;;
  *)               assert_eq "d-escalate-from-limit-monitor-prefix" "yes" "no ($FROM_D)" ;;
esac
# 7d below threshold → no escalate.
PD0=$(mk_fixture 50 98 "$RESETS_ISO")
run_check "$PD0" "$BEFORE_RESET"
N_ESC_D0=$(count_lines "$(bus_path "$PD0")" '"type":"usage-limit-7d-escalate"')
assert_eq "d-7d-98-no-escalate" "0" "$N_ESC_D0"
rm -rf "$PD0"
rm -rf "$PD"

# ================= existing idle suite still green (additive proof) =========
IDLE_GREEN="skipped"
if [ -f "$ROOT/tests/idle-monitor-per-role-wake.sh" ]; then
  if bash "$ROOT/tests/idle-monitor-per-role-wake.sh" >/dev/null 2>&1; then
    IDLE_GREEN="green"
  else
    IDLE_GREEN="RED"
  fi
fi
case "$IDLE_GREEN" in
  green|skipped) assert_eq "idle-suite-still-green" "ok" "ok" ;;
  *)             assert_eq "idle-suite-still-green" "ok" "$IDLE_GREEN" ;;
esac

echo "idle-monitor-usage-limit: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
