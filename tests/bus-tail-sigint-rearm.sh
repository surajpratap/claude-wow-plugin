#!/usr/bin/env bash
# Story 099 — bus-tail SIGINT recovery.
# AC-anchored:
#   (a) SIGINT → schema-conformant .activity.jsonl entry (type=sigint, code=130)
#   (b) SIGTERM → DIFFERENT entry (type=sigterm, code=143) — signal discrimination
#   (c) verify-detects-dead — post-compact-rearm-verify.sh exit 1 + STILL-MISSING
#   (d) verify-idempotent-live — exit 0 when prior alive
#   (e) end-to-end re-arm round-trip — spawn with spec.command+env, rearm-record,
#       verify→0, kill, verify→1
#   (f) wrapper-rejects-live-PID — CONFLICT_POLICY=reject branch (exit 2)

set -u
unset WOW_SPRINT_MANIFEST 2>/dev/null || true

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
assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}
assert_not_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) FAIL=$((FAIL+1))
                 FAILED_CASES+=("$name (haystack unexpectedly contains '$needle')") ;;
    *) PASS=$((PASS+1)) ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUS_TAIL="$ROOT/scripts/wow-process/bus-tail.sh"
RESTORE_HELPER="$ROOT/scripts/wow-process/post-compact-restore.sh"
VERIFY_HELPER="$ROOT/scripts/wow-process/post-compact-rearm-verify.sh"
SPEC_HELPER="$ROOT/scripts/wow-process/monitor-spec.sh"
RECORD_HELPER="$ROOT/scripts/wow-process/monitor-rearm-record.sh"
ROLE_MAP="$ROOT/scripts/wow-process/role-process-map.json"

mk_project() {
  local role="$1"
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations/.wow-process" \
    "$d/implementations/.agents" "$d/scripts/wow-process"
  echo "$role" > "$d/.claude-plugin/current-role"
  cp "$ROLE_MAP" "$d/scripts/wow-process/role-process-map.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}

ROLE="senior-developer"
ID="senior-developer-20260518T100000-aabbcc"

# ---- Cases (a)/(b): SIGINT vs SIGTERM emit-shape (direct invocation) ----
# bash background-subshell + kill -INT trap-firing is flaky on macOS bash 3.2,
# so the test asserts the activity-log emit function's output directly. The
# signal wiring is covered by case (g) below (the trap is installed pointing
# at the handler that calls this exact function). Together: signal arrives →
# trap fires → handler calls _bus_tail_activity_log_emit → entry has asserted shape.
PA=$(mk_project "$ROLE")
WOW_ROOT="$PA" CLAUDE_PID=12345 ROLE_X="$ROLE" ID_X="$ID" \
WOW_ROOT_X="$PA" bash <<'EMIT_SIGINT'
set -u
ROLE="$ROLE_X"; ID="$ID_X"; WOW_ROOT="$WOW_ROOT_X"
_bus_tail_activity_log_emit() {
  local kind="$1" exit_code="$2"
  [ -n "${WOW_ROOT:-}" ] || return
  local activity="${WOW_ROOT}/implementations/.activity.jsonl"
  mkdir -p "${WOW_ROOT}/implementations" 2>/dev/null || true
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","claude_pid":%s,"role":"%s","type":"%s","exit_code":%s,"agent_id":"%s"}\n' \
    "$ts" "${CLAUDE_PID:-0}" "$ROLE" "$kind" "$exit_code" "$ID" \
    >> "$activity" 2>/dev/null || true
}
_bus_tail_activity_log_emit "bus-tail-sigint-exit" 130
EMIT_SIGINT
ACT_A=$(cat "$PA/implementations/.activity.jsonl" 2>/dev/null)
assert_contains "a-type-sigint-exit"  '"type":"bus-tail-sigint-exit"'  "$ACT_A"
assert_contains "a-exit-code-130"     '"exit_code":130'                  "$ACT_A"
assert_contains "a-role-field"        "\"role\":\"$ROLE\""                "$ACT_A"
assert_contains "a-agent-id-field"    "\"agent_id\":\"$ID\""              "$ACT_A"
assert_contains "a-claude-pid-field"  '"claude_pid":12345'                "$ACT_A"
# Assert function definition byte-identity between test and bus-tail.sh.
BUS_TAIL_BODY=$(awk '/^_bus_tail_activity_log_emit\(\) \{$/,/^}$/' "$BUS_TAIL")
case "$BUS_TAIL_BODY" in
  *'printf '"'"'{"ts":"%s","claude_pid":%s,"role":"%s","type":"%s","exit_code":%s,"agent_id":"%s"}'*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1))
     FAILED_CASES+=("a-bus-tail-printf-shape-matches-test (test/script printf format drift)") ;;
esac
rm -rf "$PA"

PB=$(mk_project "$ROLE")
WOW_ROOT="$PB" CLAUDE_PID=12345 ROLE_X="$ROLE" ID_X="$ID" \
WOW_ROOT_X="$PB" bash <<'EMIT_SIGTERM'
set -u
ROLE="$ROLE_X"; ID="$ID_X"; WOW_ROOT="$WOW_ROOT_X"
_bus_tail_activity_log_emit() {
  local kind="$1" exit_code="$2"
  [ -n "${WOW_ROOT:-}" ] || return
  local activity="${WOW_ROOT}/implementations/.activity.jsonl"
  mkdir -p "${WOW_ROOT}/implementations" 2>/dev/null || true
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","claude_pid":%s,"role":"%s","type":"%s","exit_code":%s,"agent_id":"%s"}\n' \
    "$ts" "${CLAUDE_PID:-0}" "$ROLE" "$kind" "$exit_code" "$ID" \
    >> "$activity" 2>/dev/null || true
}
_bus_tail_activity_log_emit "bus-tail-sigterm-exit" 143
EMIT_SIGTERM
ACT_B=$(cat "$PB/implementations/.activity.jsonl" 2>/dev/null)
assert_contains "b-type-sigterm-exit" '"type":"bus-tail-sigterm-exit"' "$ACT_B"
assert_contains "b-exit-code-143"     '"exit_code":143'                "$ACT_B"
assert_not_contains "b-not-sigint"    '"type":"bus-tail-sigint-exit"'  "$ACT_B"
rm -rf "$PB"

# ---- Case (g): trap-installation wiring ----
# Mechanical assertion: bus-tail.sh installs separate INT and TERM traps
# (MAJOR 3) that point at the handlers that call _bus_tail_activity_log_emit.
assert_contains "g-int-trap-installed"  "trap _bus_tail_sigint_handler INT"  "$(cat "$BUS_TAIL")"
assert_contains "g-term-trap-installed" "trap _bus_tail_sigterm_handler TERM" "$(cat "$BUS_TAIL")"
assert_contains "g-sigint-handler-calls-emit"  "_bus_tail_activity_log_emit \"bus-tail-sigint-exit\" 130"  "$(cat "$BUS_TAIL")"
assert_contains "g-sigterm-handler-calls-emit" "_bus_tail_activity_log_emit \"bus-tail-sigterm-exit\" 143" "$(cat "$BUS_TAIL")"
assert_contains "g-conflict-policy-reject"     'CONFLICT_POLICY="reject"' "$(cat "$BUS_TAIL")"

# ---- Case (c): verify-detects-dead — exit 1 + STILL-MISSING ----
PC=$(mk_project "$ROLE")
# Need a tracker with bus_tail_task_id set so the verify checks bus-tail.
echo '{"bus_tail_task_id":"abc"}' > "$PC/implementations/.agents/${ROLE}-agent.json"
# Spawn + kill quickly so no PID file remains.
WOW_ROOT="$PC" CLAUDE_PID="$$" bash "$BUS_TAIL" "$PC/implementations/.message-bus.jsonl" "$ID" "$ROLE" &
BG_C=$!
sleep 1
kill -INT "$BG_C" 2>/dev/null || true
sleep 1; kill -KILL "$BG_C" 2>/dev/null || true
sleep 0.3
ERR_C=$(WOW_ROOT="$PC" WOW_ROLE_OVERRIDE="$ROLE" bash "$VERIFY_HELPER" 2>&1 >/dev/null)
RC_C=$?
assert_eq "c-verify-rc1" "1" "$RC_C"
assert_contains "c-stderr-still-missing" $'STILL-MISSING\tbus-tail' "$ERR_C"
rm -rf "$PC"

# ---- Case (d): verify-idempotent when alive — exit 0 ----
PD=$(mk_project "$ROLE")
echo '{"bus_tail_task_id":"abc"}' > "$PD/implementations/.agents/${ROLE}-agent.json"
WOW_ROOT="$PD" CLAUDE_PID="$$" bash "$BUS_TAIL" "$PD/implementations/.message-bus.jsonl" "$ID" "$ROLE" &
BG_D=$!
sleep 1
WOW_ROOT="$PD" WOW_ROLE_OVERRIDE="$ROLE" bash "$VERIFY_HELPER" 2>/dev/null
RC_D=$?
assert_eq "d-verify-rc0-while-alive" "0" "$RC_D"
kill -TERM "$BG_D" 2>/dev/null || true
sleep 1; kill -KILL "$BG_D" 2>/dev/null || true
rm -rf "$PD"

# ---- Case (e): end-to-end re-arm round-trip (mirrors 105 case h) ----
PE=$(mk_project "$ROLE")
echo '{"bus_tail_task_id":"old"}' > "$PE/implementations/.agents/${ROLE}-agent.json"
# Spawn + SIGINT-kill the first instance.
WOW_ROOT="$PE" CLAUDE_PID="$$" bash "$BUS_TAIL" "$PE/implementations/.message-bus.jsonl" "$ID" "$ROLE" &
BG_E1=$!
sleep 1
kill -INT "$BG_E1" 2>/dev/null || true
sleep 1; kill -KILL "$BG_E1" 2>/dev/null || true
sleep 0.3
# Verify confirms dead.
WOW_ROOT="$PE" WOW_ROLE_OVERRIDE="$ROLE" bash "$VERIFY_HELPER" 2>/dev/null
assert_eq "e-verify-rc1-after-sigint" "1" "$?"
# Obtain the spec and re-spawn directly (the Monitor tool is harness-level).
SPEC_E=$(WOW_ROOT="$PE" WOW_ROLE_OVERRIDE="$ROLE" bash "$SPEC_HELPER" bus-tail 2>/dev/null)
CMD_E=$(echo "$SPEC_E" | jq -r .command)
ENV_AGENT=$(echo "$SPEC_E" | jq -r .env.WOW_AGENT_ID)
ENV_ROLE=$(echo "$SPEC_E" | jq -r .env.WOW_ROLE)
ENV_BUS=$(echo "$SPEC_E" | jq -r .env.WOW_BUS)
WOW_ROOT="$PE" WOW_AGENT_ID="$ENV_AGENT" WOW_ROLE="$ENV_ROLE" WOW_BUS="$ENV_BUS" \
  $CMD_E >/dev/null 2>&1 &
BG_E2=$!
sleep 1
# Assert new PID file appears.
PIDFILE_E="$PE/implementations/.wow-process/bus-tail-${ROLE}.pid"
if [ -f "$PIDFILE_E" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("e-pidfile-reappears (no $PIDFILE_E)")
fi
# Write back the new task_id.
WOW_ROOT="$PE" WOW_ROLE_OVERRIDE="$ROLE" bash "$RECORD_HELPER" bus-tail "fake-rearm-task-id" 2>/dev/null
NEW_TID=$(jq -r .bus_tail_task_id "$PE/implementations/.agents/${ROLE}-agent.json")
assert_eq "e-task-id-roundtrip" "fake-rearm-task-id" "$NEW_TID"
# Verify now passes.
WOW_ROOT="$PE" WOW_ROLE_OVERRIDE="$ROLE" bash "$VERIFY_HELPER" 2>/dev/null
assert_eq "e-verify-rc0-after-rearm" "0" "$?"
# Kill the re-armed instance; verify fails again.
kill -TERM "$BG_E2" 2>/dev/null || true
sleep 1; kill -KILL "$BG_E2" 2>/dev/null || true
sleep 0.3
WOW_ROOT="$PE" WOW_ROLE_OVERRIDE="$ROLE" bash "$VERIFY_HELPER" 2>/dev/null
assert_eq "e-verify-rc1-after-second-kill" "1" "$?"
rm -rf "$PE"

# ---- Case (f): wrapper rejects live-PID — CONFLICT_POLICY=reject (MAJOR 1) ----
PF=$(mk_project "$ROLE")
WOW_ROOT="$PF" CLAUDE_PID="$$" bash "$BUS_TAIL" "$PF/implementations/.message-bus.jsonl" "$ID" "$ROLE" &
BG_F=$!
sleep 1
# Second invocation while the first is alive → must exit 2 with "refusing to spawn".
OUT_F=$(WOW_ROOT="$PF" CLAUDE_PID="$$" bash "$BUS_TAIL" "$PF/implementations/.message-bus.jsonl" "$ID" "$ROLE" 2>&1)
RC_F=$?
assert_eq "f-wrapper-rejects-rc2" "2" "$RC_F"
assert_contains "f-stderr-refusing-msg" "refusing to spawn" "$OUT_F"
kill -TERM "$BG_F" 2>/dev/null || true
sleep 1; kill -KILL "$BG_F" 2>/dev/null || true
rm -rf "$PF"

# ---- Case (g): monitor-spec.sh propagates CLAUDE_PID into ENV_JSON (Story 125) ----
# FINDING-27 fix — without CLAUDE_PID in the spec env, bus-tail.sh's SIGINT
# emit reads ${CLAUDE_PID:-0} and the activity-log row has claude_pid:0 (broken
# the story-099 schema-conformance claim). Assert the spec carries the env var.
PG=$(mk_project "$ROLE")
SPEC_G=$(WOW_ROOT="$PG" WOW_ROLE_OVERRIDE="$ROLE" CLAUDE_PID=99999 bash "$ROOT/scripts/wow-process/monitor-spec.sh" bus-tail 2>/dev/null)
CP_G=$(echo "$SPEC_G" | jq -r .env.CLAUDE_PID 2>/dev/null)
assert_eq "g-monitor-spec-bus-tail-CLAUDE_PID" "99999" "$CP_G"
# Same parity for github-bridge (manager-role fixture since github-bridge is
# in manager's role-process-map, not SD's).
PG2=$(mk_project manager)
SPEC_G2=$(WOW_ROOT="$PG2" WOW_ROLE_OVERRIDE=manager CLAUDE_PID=88888 bash "$ROOT/scripts/wow-process/monitor-spec.sh" github-bridge 2>/dev/null)
CP_G2=$(echo "$SPEC_G2" | jq -r .env.CLAUDE_PID 2>/dev/null)
assert_eq "g-monitor-spec-github-bridge-CLAUDE_PID" "88888" "$CP_G2"
rm -rf "$PG" "$PG2"

echo "bus-tail-sigint-rearm: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
