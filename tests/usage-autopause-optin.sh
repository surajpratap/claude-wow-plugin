#!/usr/bin/env bash
# Story 172 — AC1 explicit opt-in gate for the idle-limit-monitor codepath.
#
# Behavioral. The 5h limit codepath must act ONLY when the human opted in. The
# gate at the TOP of `_check_usage_limits()` reads WOW_USAGE_AUTOPAUSE (the test
# override) ELSE M's tracker `usage_autopause`; default (unset) = FALSE → return
# early, emitting NOTHING — even with a >=98 state file present.
#
# Cases:
#   (a) opt-in FALSE + 5h>=98 state present → NO usage-limit-pause on the bus.
#   (b) opt-in TRUE  + same state           → exactly ONE usage-limit-pause.
#   (c) opt-in unset (no env, no tracker flag) + same state → NO emit (default off).
#   (d) tracker flag usage_autopause:true (no env) → emits (M's persisted opt-in).
#
# RED-WITHOUT: patch .red-without/opt-in-gate.patch -> a-optin-false-no-emit

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
  echo "usage-autopause-optin: SKIP — $IDLE_MONITOR not found"
  exit 0
fi
if ! python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('idle_monitor','$IDLE_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import sys; sys.exit(0 if hasattr(m,'_check_usage_limits') else 1)
" 2>/dev/null; then
  echo "usage-autopause-optin: SKIP — _check_usage_limits not present yet"
  exit 0
fi

RESETS_ISO="2026-05-31T12:00:00Z"
RESETS_EPOCH=$(python3 -c "import datetime;print(int(datetime.datetime.fromisoformat('2026-05-31T12:00:00+00:00').timestamp()))")
BEFORE_RESET=$((RESETS_EPOCH - 600))

# mk_fixture — a >=98 5h state file is ALWAYS present; the gate (not the state)
# decides whether the pause fires.
mk_fixture() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations/.wow-process" "$d/implementations/.agents"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  cat > "$d/implementations/.wow-process/five-hour-usage.json" <<JSON
{"five_hour":{"used_percentage":99,"resets_at":"$RESETS_ISO"},"seven_day":{"used_percentage":10,"resets_at":"2026-06-05T00:00:00Z"},"captured_ts":1}
JSON
  echo "$d"
}

bus_path() { echo "$1/implementations/.message-bus.jsonl"; }

count_lines() {
  local f="$1" pat="$2" n
  [ -f "$f" ] || { echo 0; return; }
  n=$(grep -cF -- "$pat" "$f" 2>/dev/null)
  echo "${n:-0}"
}

# run_check <proj> <optin-env-or-empty> — optin-env is the literal value of
# WOW_USAGE_AUTOPAUSE; pass the sentinel "UNSET" to leave it unset entirely.
run_check() {
  local proj="$1" optin="$2"
  if [ "$optin" = "UNSET" ]; then
    ( cd "$proj" && env -u WOW_USAGE_AUTOPAUSE \
      CLAUDE_PROJECT_DIR="$proj" WOW_ROOT="$proj" WOW_IDLE_NOW_EPOCH="$BEFORE_RESET" \
      python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('idle_monitor','$IDLE_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._check_usage_limits('$proj')
" > "$proj/stdout.txt" 2> "$proj/stderr.txt" )
  else
    ( cd "$proj" && \
      CLAUDE_PROJECT_DIR="$proj" WOW_ROOT="$proj" WOW_IDLE_NOW_EPOCH="$BEFORE_RESET" \
      WOW_USAGE_AUTOPAUSE="$optin" \
      python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('idle_monitor','$IDLE_MONITOR')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._check_usage_limits('$proj')
" > "$proj/stdout.txt" 2> "$proj/stderr.txt" )
  fi
}

# ================= (a) opt-in FALSE + >=98 → NO emit (gate blocks) =================
PA=$(mk_fixture)
run_check "$PA" "0"
N_A=$(count_lines "$(bus_path "$PA")" '"type":"usage-limit-pause"')
assert_eq "a-optin-false-no-emit" "0" "$N_A"
rm -rf "$PA"

# ================= (b) opt-in TRUE + same state → ONE pause =================
PB=$(mk_fixture)
run_check "$PB" "1"
N_B=$(count_lines "$(bus_path "$PB")" '"type":"usage-limit-pause"')
assert_eq "b-optin-true-emits" "1" "$N_B"
rm -rf "$PB"

# ================= (c) opt-in UNSET (no env, no tracker) → NO emit (default off) ===
PC=$(mk_fixture)
run_check "$PC" "UNSET"
N_C=$(count_lines "$(bus_path "$PC")" '"type":"usage-limit-pause"')
assert_eq "c-optin-unset-default-off" "0" "$N_C"
rm -rf "$PC"

# ================= (d) tracker flag usage_autopause:true (no env) → emits =========
PD=$(mk_fixture)
cat > "$PD/implementations/.agents/manager-20260531T120000-a1b2c3.json" <<JSON
{"claude_pid":1,"usage_autopause":true}
JSON
run_check "$PD" "UNSET"
N_D=$(count_lines "$(bus_path "$PD")" '"type":"usage-limit-pause"')
assert_eq "d-tracker-flag-emits" "1" "$N_D"
rm -rf "$PD"

echo "usage-autopause-optin: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
