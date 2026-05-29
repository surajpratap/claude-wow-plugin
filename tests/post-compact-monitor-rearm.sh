#!/usr/bin/env bash
# Story 105 — post-compact monitor re-arm helpers.
#
# AC-anchored coverage:
#   1. tracker-armed-purposes.sh — lists set *_task_id keys
#   2. monitor-spec.sh — JSON spec shape per purpose
#   3. monitor-rearm-record.sh — writes task_id back to tracker
#   4. post-compact-restore.sh — tab-separated MISSING for tracker-armed
#   5. post-compact-rearm-verify.sh — exit 0/1 + STILL-MISSING shape
#   6. doctrine coherence — "Never substitute" present in all 5 role files

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
TRACKER_HELPER="$ROOT/scripts/wow-process/tracker-armed-purposes.sh"
SPEC_HELPER="$ROOT/scripts/wow-process/monitor-spec.sh"
RECORD_HELPER="$ROOT/scripts/wow-process/monitor-rearm-record.sh"
RESTORE_HELPER="$ROOT/scripts/wow-process/post-compact-restore.sh"
VERIFY_HELPER="$ROOT/scripts/wow-process/post-compact-rearm-verify.sh"
ROLE_MAP="$ROOT/scripts/wow-process/role-process-map.json"

# mk_project <role> [<tracker-json>]
# Builds an isolated WOW_ROOT with role marker, role-process-map, and an
# agent tracker (optional). Returns the dir.
mk_project() {
  local role="$1" tracker_json="${2:-}"
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations/.wow-process" \
    "$d/implementations/.agents" "$d/scripts/wow-process"
  echo "$role" > "$d/.claude-plugin/current-role"
  cp "$ROLE_MAP" "$d/scripts/wow-process/role-process-map.json"
  if [ -n "$tracker_json" ]; then
    echo "$tracker_json" > "$d/implementations/.agents/${role}-agent.json"
  fi
  echo "$d"
}

# ---- Case (a): tracker-armed-purposes lists set *_task_id keys ----
PA=$(mk_project senior-developer '{"last_line":0,"bus_tail_task_id":"abc123","github_bridge_task_id":null}')
OUT_A=$(WOW_ROOT="$PA" WOW_ROLE_OVERRIDE=senior-developer bash "$TRACKER_HELPER" 2>/dev/null)
assert_eq "a-bus-tail-listed" "bus-tail" "$OUT_A"
rm -rf "$PA"

# Also assert null value is OMITTED (M's optional github-bridge case).
PA2=$(mk_project manager '{"bus_tail_task_id":"x","github_bridge_task_id":null,"idle_monitor_task_id":"y"}')
OUT_A2=$(WOW_ROOT="$PA2" WOW_ROLE_OVERRIDE=manager bash "$TRACKER_HELPER" 2>/dev/null | sort | tr '\n' ',')
assert_eq "a-null-omitted" "bus-tail,idle-monitor," "$OUT_A2"
rm -rf "$PA2"

# ---- Case (b): post-compact-restore MISSING only for tracker-armed ----
# Manager role-process-map has bus-tail, github-bridge, idle-monitor.
# Tracker has bus-tail armed, github-bridge=null, idle-monitor armed.
# Expected: MISSING lines for bus-tail and idle-monitor; NO github-bridge line.
PB=$(mk_project manager '{"bus_tail_task_id":"x","github_bridge_task_id":null,"idle_monitor_task_id":"y"}')
OUT_B=$(WOW_ROOT="$PB" WOW_ROLE_OVERRIDE=manager bash "$RESTORE_HELPER" 2>/dev/null)
assert_contains "b-MISSING-bus-tail" $'MISSING\tbus-tail' "$OUT_B"
assert_contains "b-MISSING-idle-monitor" $'MISSING\tidle-monitor' "$OUT_B"
# Anchor on the MISSING<TAB>purpose line, not a bare "github-bridge" substring —
# the MISSING paths embed WOW_ROOT, and a worktree slug like
# "164-github-bridge-poll-state-open" would otherwise false-positive.
assert_not_contains "b-no-github-bridge" $'MISSING\tgithub-bridge' "$OUT_B"
rm -rf "$PB"

# ---- Case (c): monitor-spec.sh JSON shape ----
PC=$(mk_project senior-developer '{"bus_tail_task_id":"x"}')
SPEC_C=$(WOW_ROOT="$PC" WOW_ROLE_OVERRIDE=senior-developer bash "$SPEC_HELPER" bus-tail 2>/dev/null)
# Parse the JSON; assert required keys present.
HAS_KEYS=$(echo "$SPEC_C" | jq -r 'has("command") and has("env") and has("description") and has("purpose") and has("tracker_field")')
assert_eq "c-spec-has-required-keys" "true" "$HAS_KEYS"
TRACKER_FIELD=$(echo "$SPEC_C" | jq -r '.tracker_field')
assert_eq "c-tracker-field-naming" "bus_tail_task_id" "$TRACKER_FIELD"
CMD=$(echo "$SPEC_C" | jq -r '.command')
assert_contains "c-cmd-references-wrap" "bus-tail.sh" "$CMD"
rm -rf "$PC"

# ---- Case (d): monitor-spec.sh exit 1 on unknown purpose ----
PD=$(mk_project senior-developer '{}')
WOW_ROOT="$PD" WOW_ROLE_OVERRIDE=senior-developer bash "$SPEC_HELPER" totally-bogus 2>/dev/null
assert_eq "d-bogus-purpose-rc1" "1" "$?"
rm -rf "$PD"

# ---- Case (e): monitor-rearm-record.sh writes back to tracker ----
PE=$(mk_project senior-developer '{"bus_tail_task_id":"old"}')
WOW_ROOT="$PE" WOW_ROLE_OVERRIDE=senior-developer bash "$RECORD_HELPER" bus-tail new-task-id-42 2>/dev/null
NEW_VAL=$(jq -r .bus_tail_task_id "$PE/implementations/.agents/senior-developer-agent.json")
assert_eq "e-task-id-written" "new-task-id-42" "$NEW_VAL"
rm -rf "$PE"

# ---- Case (f): post-compact-rearm-verify.sh — happy path (all alive) ----
PF=$(mk_project senior-developer '{"bus_tail_task_id":"x"}')
echo "$$" > "$PF/implementations/.wow-process/bus-tail-senior-developer.pid"
WOW_ROOT="$PF" WOW_ROLE_OVERRIDE=senior-developer bash "$VERIFY_HELPER" 2>/dev/null
assert_eq "f-verify-all-alive-rc0" "0" "$?"
rm -rf "$PF"

# ---- Case (g): post-compact-rearm-verify.sh — fail path + STILL-MISSING ----
PG=$(mk_project senior-developer '{"bus_tail_task_id":"x"}')
# No PID file for bus-tail → STILL-MISSING expected.
ERR_G=$(WOW_ROOT="$PG" WOW_ROLE_OVERRIDE=senior-developer bash "$VERIFY_HELPER" 2>&1 >/dev/null)
RC_G=$?
assert_eq "g-verify-missing-rc1" "1" "$RC_G"
assert_contains "g-verify-stderr-shape" $'STILL-MISSING\tbus-tail' "$ERR_G"
rm -rf "$PG"

# ---- Case (h): end-to-end re-arm round trip ----
# Spawn a wrapped script with the spec's command+env in the test (the
# Monitor tool is harness-level; we test that the spec is faithful by
# running the wrapped script directly and asserting the PID file appears).
PH=$(mk_project senior-developer '{"bus_tail_task_id":"old"}')
# Get the spec.
SPEC_H=$(WOW_ROOT="$PH" WOW_ROLE_OVERRIDE=senior-developer bash "$SPEC_HELPER" bus-tail 2>/dev/null)
# Set up a fake message bus so bus-tail.sh doesn't choke on missing file.
touch "$PH/implementations/.message-bus.jsonl"
# Run the spec's command in background under WOW_ROOT scope. bus-tail.sh
# writes its PID file on spawn; we sleep briefly then assert the file
# exists, then SIGTERM the child.
CMD_H=$(echo "$SPEC_H" | jq -r '.command')
# Story 163: CMD now includes a pipe (`| bash monitor-pipe.sh ...`).
# Case (h)'s contract is "does the wrapped bus-tail.sh spawn + write its
# PID file" — the pipe portion is verified separately in case (m).
# Strip the pipe so we can run just the wrap script and SIGTERM it
# cleanly without leaking the monitor-pipe child. Use eval so the shell
# parses the string's quoted paths/args correctly.
WRAP_CMD_H=$(echo "$CMD_H" | sed -E 's/[[:space:]]*\|.*$//')
eval "WOW_ROOT=\"$PH\" $WRAP_CMD_H >/dev/null 2>&1 &"
BG_PID=$!
sleep 1
PIDFILE_H="$PH/implementations/.wow-process/bus-tail-senior-developer.pid"
if [ -f "$PIDFILE_H" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("h-pidfile-created-after-spawn (pidfile $PIDFILE_H not found)")
fi
# Record the task_id back, verify tracker.
WOW_ROOT="$PH" WOW_ROLE_OVERRIDE=senior-developer bash "$RECORD_HELPER" bus-tail "fake-task-roundtrip" 2>/dev/null
ROUNDTRIP=$(jq -r .bus_tail_task_id "$PH/implementations/.agents/senior-developer-agent.json")
assert_eq "h-task-id-roundtrip" "fake-task-roundtrip" "$ROUNDTRIP"
# Verify says all-alive while bus-tail child is alive.
WOW_ROOT="$PH" WOW_ROLE_OVERRIDE=senior-developer bash "$VERIFY_HELPER" 2>/dev/null
assert_eq "h-verify-rc0-while-alive" "0" "$?"
# Kill the bg child; verify now fails.
kill -TERM "$BG_PID" 2>/dev/null || true
sleep 1
WOW_ROOT="$PH" WOW_ROLE_OVERRIDE=senior-developer bash "$VERIFY_HELPER" 2>/dev/null
assert_eq "h-verify-rc1-after-kill" "1" "$?"
rm -rf "$PH"

# ---- Case (i): doctrine coherence — "Never substitute a poll-based Bash watcher" ----
CMD="$ROOT/commands"
for role in senior-developer manager pair-programmer tester slacker; do
  if grep -qF "poll-based Bash watcher" "$CMD/$role.md"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("i-doctrine-$role (missing 'poll-based Bash watcher')")
  fi
done

# ---- Case (j): _agent-protocol.md compaction-occurred row references the new helpers ----
assert_contains "j-protocol-mentions-monitor-spec" "monitor-spec.sh" "$(cat "$CMD/_agent-protocol.md")"
assert_contains "j-protocol-mentions-rearm-verify" "post-compact-rearm-verify.sh" "$(cat "$CMD/_agent-protocol.md")"

# ---- Case (k): idle-monitor.sh PID-file path follows the convention ----
assert_contains "k-idle-monitor-uses-convention-path" 'idle-monitor-${WOW_ROLE' "$(cat "$ROOT/scripts/wow-process/idle-monitor.sh")"

# ---- Case (l) — Story 126 (FINDING-28): empty tracker (rc=0, no armed keys)
# must NOT trigger the role-process-map fallback. Only rc=2 (tracker file
# not resolvable) fires the fallback.
PL1=$(mk_project senior-developer '{}')
ERR_L1=$(WOW_ROOT="$PL1" WOW_ROLE_OVERRIDE=senior-developer bash "$RESTORE_HELPER" 2>&1 >/dev/null)
OUT_L1=$(WOW_ROOT="$PL1" WOW_ROLE_OVERRIDE=senior-developer bash "$RESTORE_HELPER" 2>/dev/null)
assert_eq "l-empty-tracker-no-stdout" "" "$OUT_L1"
case "$ERR_L1" in
  *"falling back to role-process-map walk"*)
    FAIL=$((FAIL+1))
    FAILED_CASES+=("l-empty-tracker-no-fallback (fallback fired on empty-tracker rc=0)") ;;
  *) PASS=$((PASS+1)) ;;
esac
rm -rf "$PL1"

# Missing-tracker case: NO tracker file at all → fallback should fire.
PL2=$(mk_project manager)
ERR_L2=$(WOW_ROOT="$PL2" WOW_ROLE_OVERRIDE=manager bash "$RESTORE_HELPER" 2>&1 >/dev/null)
assert_contains "l-missing-tracker-fallback-fires" "falling back to role-process-map walk" "$ERR_L2"
rm -rf "$PL2"

# ---- Case (m) — Bug 0007 (HIGH): monitor-spec.sh CMD pipes through
# monitor-pipe.sh for every purpose. Pre-fix monitor-spec.sh emitted bare
# `bash <wrap> [args]` commands; post-compact Monitors emitted raw event
# text instead of Story 154's pointer + read-tool pattern. This BEHAVIORAL
# assertion verifies the actual CMD string carries the pipe-wrap.
# All three purposes (bus-tail, github-bridge, idle-monitor) live in
# manager's role-process-map; use manager throughout for uniform setup.
for purpose in bus-tail github-bridge idle-monitor; do
  PM=$(mk_project manager '{"bus_tail_task_id":"x","github_bridge_task_id":"y","idle_monitor_task_id":"z"}')
  SPEC_M=$(WOW_ROOT="$PM" WOW_ROLE_OVERRIDE=manager bash "$SPEC_HELPER" "$purpose" 2>/dev/null)
  CMD_M=$(echo "$SPEC_M" | jq -r '.command')
  if echo "$CMD_M" | grep -qE "monitor-pipe\.sh.*--purpose $purpose"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("m-$purpose-pipes-monitor-pipe (CMD='$CMD_M')")
  fi
  rm -rf "$PM"
done

echo "post-compact-monitor-rearm: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
