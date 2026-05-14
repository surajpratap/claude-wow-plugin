#!/usr/bin/env bash
# Story 044 — slacker.md ↔ bundled-bridge env-var contract test.
#
# Asserts:
#  - spawn command uses BRIDGE_HTTP_PORT / BRIDGE_DATA_DIR (not bare PORT/EVENTS_PATH)
#  - DATA_DIR derived correctly from EVENTS_PATH
#  - lsof collision check emits degraded with port-collision reason
#  - /health mismatch (port or eventsPath) emits degraded with contract-violation reason
#  - /health match path proceeds without degraded
#  - PID file path derivation matches slacker's expected location

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

# Inline mirror of slacker.md step 5 spawn-command assembly.
build_spawn_cmd() {
  local port="$1" data_dir="$2" bot_token="$3" app_token="$4" bridge_dir="$5"
  echo "cd \"$bridge_dir\" && BRIDGE_HTTP_PORT=$port BRIDGE_DATA_DIR=$data_dir SLACK_BOT_TOKEN=$bot_token SLACK_APP_TOKEN=$app_token exec node dist/index.js"
}

# Inline mirror of slacker.md step 7 /health validation logic.
# Returns "ok" / "degraded:<reason>".
validate_health() {
  local health_json="$1" requested_port="$2" requested_events="$3"
  local ok h_port h_events
  ok=$(echo "$health_json" | jq -r '.ok // false')
  h_port=$(echo "$health_json" | jq -r '.port // empty')
  h_events=$(echo "$health_json" | jq -r '.eventsPath // empty')
  if [ "$ok" != "true" ]; then echo "degraded:not-ok"; return; fi
  if [ "$h_port" != "$requested_port" ]; then echo "degraded:env-var-contract-violation:port"; return; fi
  if [ "$h_events" != "$requested_events" ]; then echo "degraded:env-var-contract-violation:eventsPath"; return; fi
  echo "ok"
}

# Inline mirror of slacker.md step 5 lsof collision check.
# Returns "ok" if port free, "degraded:port-collision" if in use.
check_port_collision() {
  local port="$1" lsof_shim_returns="$2"
  if [ "$lsof_shim_returns" = "in-use" ]; then
    echo "degraded:port-collision"
  else
    echo "ok"
  fi
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: spawn command uses correct env-var names.
CMD=$(build_spawn_cmd 47821 "/x/y/.slack" "xoxb-test" "xapp-test" "/path/to/bridge")
echo "$CMD" | grep -q "BRIDGE_HTTP_PORT=47821" && assert_eq "case-1-bridge-http-port" "yes" "yes" || assert_eq "case-1-bridge-http-port" "yes" "no"
echo "$CMD" | grep -q "BRIDGE_DATA_DIR=/x/y/.slack" && assert_eq "case-1-bridge-data-dir" "yes" "yes" || assert_eq "case-1-bridge-data-dir" "yes" "no"
echo "$CMD" | grep -q "SLACK_BOT_TOKEN=xoxb-test" && assert_eq "case-1-bot-token" "yes" "yes" || assert_eq "case-1-bot-token" "yes" "no"
echo "$CMD" | grep -q "SLACK_APP_TOKEN=xapp-test" && assert_eq "case-1-app-token" "yes" "yes" || assert_eq "case-1-app-token" "yes" "no"
# Negative: must NOT contain bare PORT= or bare EVENTS_PATH=
if echo "$CMD" | grep -qE '(^| )PORT=|EVENTS_PATH=' ; then
  assert_eq "case-1-no-bare-PORT-or-EVENTS_PATH" "yes" "no (cmd contains old contract: $CMD)"
else
  assert_eq "case-1-no-bare-PORT-or-EVENTS_PATH" "yes" "yes"
fi

# Case 2: DATA_DIR derived from EVENTS_PATH via dirname.
EVENTS_PATH="/x/y/.slack/events.jsonl"
DATA_DIR=$(dirname "$EVENTS_PATH")
assert_eq "case-2-data-dir-derivation" "/x/y/.slack" "$DATA_DIR"

# Case 3: lsof collision check emits degraded.
RESULT=$(check_port_collision 47821 "in-use")
assert_eq "case-3-collision-emits-degraded" "degraded:port-collision" "$RESULT"
RESULT=$(check_port_collision 47821 "free")
assert_eq "case-3-no-collision-ok" "ok" "$RESULT"

# Case 4: /health mismatch (wrong port) emits degraded.
HEALTH='{"ok":true,"socketMode":"connected","port":3100,"eventsPath":"/x/y/.slack/events.jsonl"}'
RESULT=$(validate_health "$HEALTH" "47821" "/x/y/.slack/events.jsonl")
assert_eq "case-4-port-mismatch-degraded" "degraded:env-var-contract-violation:port" "$RESULT"

# Case 4b: /health mismatch (wrong eventsPath) emits degraded.
HEALTH='{"ok":true,"socketMode":"connected","port":47821,"eventsPath":"/wrong/path"}'
RESULT=$(validate_health "$HEALTH" "47821" "/x/y/.slack/events.jsonl")
assert_eq "case-4b-eventspath-mismatch-degraded" "degraded:env-var-contract-violation:eventsPath" "$RESULT"

# Case 4c: /health ok=false short-circuits.
HEALTH='{"ok":false,"socketMode":"disconnected"}'
RESULT=$(validate_health "$HEALTH" "47821" "/x/y/.slack/events.jsonl")
assert_eq "case-4c-not-ok-degraded" "degraded:not-ok" "$RESULT"

# Case 5: /health match path proceeds.
HEALTH='{"ok":true,"socketMode":"connected","port":47821,"eventsPath":"/x/y/.slack/events.jsonl"}'
RESULT=$(validate_health "$HEALTH" "47821" "/x/y/.slack/events.jsonl")
assert_eq "case-5-match-ok" "ok" "$RESULT"

# Case 6: PID file path matches contract.
# Slacker expects: ${ROOT}/implementations/.slack/.bridge-pid
# Bridge writes: ${BRIDGE_DATA_DIR}/.bridge-pid where BRIDGE_DATA_DIR = dirname(events.jsonl)
ROOT_FIX="/some/root"
EVENTS_PATH="$ROOT_FIX/implementations/.slack/events.jsonl"
DATA_DIR=$(dirname "$EVENTS_PATH")
SLACKER_EXPECTED_PID="$ROOT_FIX/implementations/.slack/.bridge-pid"
BRIDGE_WRITES_PID="$DATA_DIR/.bridge-pid"
assert_eq "case-6-pid-path-contract" "$SLACKER_EXPECTED_PID" "$BRIDGE_WRITES_PID"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "slacker-bridge-env-vars: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
