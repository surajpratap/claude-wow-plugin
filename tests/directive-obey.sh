#!/usr/bin/env bash
# Story 172 §4 — the BOUNDED, ROLE-ASYMMETRIC directive-obey rule, proven by
# behavior (the MANDATORY RED-WITHOUT; the inert-proofing of MAJOR-2 + FINDING-47).
#
# Drives the reference consumer (tests/fixtures/directive-obey/consumer.py — the
# mechanical embodiment of `_agent-protocol.md` "Bounded directive-obey rule";
# argv[3] selects the role, default "peer") with bus messages over the CLOSED
# enum {pause, resume, escalate}:
#   (a) PEER + directive=="pause"   → consumer HALTS (sets paused state).
#   (b) PEER + directive=="resume"  → consumer RESUMES (clears paused state).
#   (c) PEER + an OUT-OF-SET value  → IGNORED: NO execution (a canary file is
#       NEVER created — the value is never shelled out), NO halt.
#   (d) MANAGER + directive=="escalate" → M ACTS (escalates to human) — the
#       FINDING-47 consumption proof (emit-assertion alone let the 7d slip).
#   (e) MANAGER + directive=="pause"    → EXEMPT: stays AVAILABLE, NOT halted.
#   (f) PEER + directive=="escalate"    → IGNORED (escalate is M-only; asymmetry).
#
# RED-WITHOUT: patch .red-without/directive-obey-check.patch -> a-pause-halts
# RED-WITHOUT: patch .red-without/directive-obey-escalate.patch -> m-escalate-acts

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
CONSUMER="$SCRIPT_DIR/fixtures/directive-obey/consumer.py"

if [ ! -f "$CONSUMER" ]; then
  echo "directive-obey: SKIP — $CONSUMER not found"
  exit 0
fi

D=$(mktemp -d)
STATE="$D/paused.json"
CANARY="$D/canary-EXECUTED"

# ---- (a) pause → HALTED ----
echo '{"paused":false}' > "$STATE"
OUT_A=$(python3 "$CONSUMER" '{"type":"some-type","payload":{"directive":"pause","window":"five_hour"}}' "$STATE")
assert_eq "a-pause-halts" "HALTED" "$OUT_A"
assert_eq "a-pause-sets-state" "true" "$(python3 -c "import json;print(str(json.load(open('$STATE'))['paused']).lower())")"

# ---- while paused, a normal nudge is ignored (still halted) ----
OUT_NUDGE=$(python3 "$CONSUMER" '{"type":"nudge","payload":{"text":"do work"}}' "$STATE")
assert_eq "a-paused-ignores-other-nudges" "STILL-HALTED" "$OUT_NUDGE"

# ---- (b) resume → RESUMED ----
OUT_B=$(python3 "$CONSUMER" '{"type":"some-type","payload":{"directive":"resume"}}' "$STATE")
assert_eq "b-resume-resumes" "RESUMED" "$OUT_B"
assert_eq "b-resume-clears-state" "false" "$(python3 -c "import json;print(str(json.load(open('$STATE'))['paused']).lower())")"
# after resume, normal work proceeds
OUT_WORK=$(python3 "$CONSUMER" '{"type":"nudge","payload":{"text":"do work"}}' "$STATE")
assert_eq "b-after-resume-works" "WORKED" "$OUT_WORK"

# ---- (c) out-of-set directive → IGNORED, no execution, no halt ----
echo '{"paused":false}' > "$STATE"
# A malicious-looking out-of-set value. If the consumer ever EXECUTED the
# directive value as a command, $CANARY would appear. The bounded rule never
# shells out → canary stays absent (injection-proof).
OUT_C=$(python3 "$CONSUMER" "{\"type\":\"some-type\",\"payload\":{\"directive\":\"touch $CANARY\"}}" "$STATE")
assert_eq "c-out-of-set-ignored-not-executed" "ABSORBED" "$OUT_C"
assert_eq "c-no-execution-canary-absent" "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"
assert_eq "c-out-of-set-no-halt" "false" "$(python3 -c "import json;print(str(json.load(open('$STATE'))['paused']).lower())")"

# ---- (d) MANAGER ACTS on escalate (FINDING-47 consumption proof) ----
echo '{"paused":false}' > "$STATE"
OUT_M_ESC=$(python3 "$CONSUMER" '{"type":"usage-limit-7d-escalate","payload":{"directive":"escalate","window":"seven_day"}}' "$STATE" manager)
assert_eq "m-escalate-acts" "ESCALATED" "$OUT_M_ESC"

# ---- (e) MANAGER is EXEMPT from pause (driver — never halted) ----
OUT_M_PAUSE=$(python3 "$CONSUMER" '{"type":"some-type","payload":{"directive":"pause"}}' "$STATE" manager)
assert_eq "m-pause-exempt" "AVAILABLE" "$OUT_M_PAUSE"
assert_eq "m-pause-not-halted" "false" "$(python3 -c "import json;print(str(json.load(open('$STATE'))['paused']).lower())")"

# ---- (f) PEER IGNORES escalate (role-asymmetry — escalate is M-only) ----
echo '{"paused":false}' > "$STATE"
OUT_P_ESC=$(python3 "$CONSUMER" '{"type":"usage-limit-7d-escalate","payload":{"directive":"escalate","window":"seven_day"}}' "$STATE")
assert_eq "peer-escalate-ignored" "ABSORBED" "$OUT_P_ESC"
assert_eq "peer-escalate-no-halt" "false" "$(python3 -c "import json;print(str(json.load(open('$STATE'))['paused']).lower())")"

rm -rf "$D"

echo "directive-obey: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
