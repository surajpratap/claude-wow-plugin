#!/usr/bin/env bash
# Story 072 — PostCompact hook + MCP CLI shim + post-compact-restore helper.
# 8 spec cases + per-role PID-naming regression guard.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$ROOT/mcp/claude-wow-server/server.py"
HOOK="$ROOT/scripts/hooks/wow-post-compact-bus-notice.sh"
HELPER="$ROOT/scripts/wow-process/post-compact-restore.sh"
ROLE_MAP="$ROOT/scripts/wow-process/role-process-map.json"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations/.wow-process" "$d/implementations/.agents" "$d/scripts/wow-process"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  # Ship a project-local copy of role-process-map.json so the helper finds it.
  cp "$ROLE_MAP" "$d/scripts/wow-process/role-process-map.json"
  echo "$d"
}

# -----------------------------------------------------------------------------
# Case 1: MCP CLI happy path — bus_emit appends correct JSONL line.
# -----------------------------------------------------------------------------
P1=$(mk_project)
CLAUDE_PROJECT_DIR="$P1" python3 "$SERVER" bus_emit \
  --from "manager-20260513T120000-aabbcc" --to "*" --type "ping" \
  --payload-json '{"nonce":"x"}' >/dev/null 2>&1
LINES1=$(wc -l < "$P1/implementations/.message-bus.jsonl" | tr -d ' ')
TYPE1=$(tail -1 "$P1/implementations/.message-bus.jsonl" | jq -r '.type // empty')
assert_eq "case-1-cli-line-written" "1"     "$LINES1"
assert_eq "case-1-cli-type-roundtrip" "ping" "$TYPE1"
rm -rf "$P1"

# -----------------------------------------------------------------------------
# Case 2: MCP CLI invalid args — exit 2 + stderr; no bus write.
# -----------------------------------------------------------------------------
P2=$(mk_project)
set +e
ERR2=$(CLAUDE_PROJECT_DIR="$P2" python3 "$SERVER" bus_emit \
  --from "not-a-valid-id" --to "*" --type "BOGUS" 2>&1 >/dev/null)
EXIT2=$?
set -e 2>/dev/null || true
LINES2=$(wc -l < "$P2/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-2-cli-invalid-exit-2" "2" "$EXIT2"
assert_eq "case-2-cli-no-bus-write"   "0" "$LINES2"
rm -rf "$P2"

# -----------------------------------------------------------------------------
# Case 3: Hook with no session-role marker — exit 0; no bus write.
# Story 049 session-role markers live at .claude/.session-role-by-claude-pid/
# <PPID>. Hook silently exits if absent.
# -----------------------------------------------------------------------------
P3=$(mk_project)
# Marker dir intentionally absent — hook should silently exit.
set +e
CLAUDE_PROJECT_DIR="$P3" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" 2>/dev/null
EXIT3=$?
set -e 2>/dev/null || true
LINES3=$(wc -l < "$P3/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-3-hook-no-role-marker-exit-0" "0" "$EXIT3"
assert_eq "case-3-hook-no-role-marker-no-bus" "0" "$LINES3"
rm -rf "$P3"

# -----------------------------------------------------------------------------
# Case 4: Hook with session-role marker + tracker — emits compaction-occurred
# AND bus-tail forwards it (passes self-echo filter via synthetic sender).
# Spawns bus-tail.sh briefly and captures stdout; asserts the line appears.
# -----------------------------------------------------------------------------
P4=$(mk_project)
AGENT_ID="manager-20260513T120000-aabbcc"
mkdir -p "$P4/.claude/.session-role-by-claude-pid"
# PPID of `bash "$HOOK"` will be this test's shell. The hook uses $PPID
# (= the bash subshell that exec'd the hook). Use a wrapper that pins
# PPID by passing through bash -c (parent shell PID).
PARENT_PID=$$
echo "manager" > "$P4/.claude/.session-role-by-claude-pid/$PARENT_PID"
echo "{\"agent_id\": \"$AGENT_ID\", \"last_line\": 0}" > "$P4/implementations/.agents/$AGENT_ID.json"

# Invoke hook in current shell context so $PPID inside the hook = $PARENT_PID
# (the hook reads $PPID — direct invocation, no subshell wrap).
CLAUDE_PROJECT_DIR="$P4" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" 2>/dev/null

# Verify bus has the line.
LINES4=$(wc -l < "$P4/implementations/.message-bus.jsonl" | tr -d ' ')
TYPE4=$(tail -1 "$P4/implementations/.message-bus.jsonl" | jq -r '.type // empty')
TO4=$(tail -1 "$P4/implementations/.message-bus.jsonl" | jq -r '.to // empty')
FROM4=$(tail -1 "$P4/implementations/.message-bus.jsonl" | jq -r '.from // empty')
ROLE4=$(tail -1 "$P4/implementations/.message-bus.jsonl" | jq -r '.payload.role // empty')
assert_eq        "case-4-hook-line-emitted"  "1"                     "$LINES4"
assert_eq        "case-4-hook-type"          "compaction-occurred"   "$TYPE4"
assert_eq        "case-4-hook-to-agent"      "$AGENT_ID"             "$TO4"
assert_eq        "case-4-hook-payload-role"  "manager"               "$ROLE4"
assert_contains  "case-4-hook-synth-from"    "postcompact-hook-"     "$FROM4"

# Now verify bus-tail actually forwards the line (the self-echo filter
# `.from != $agent` must NOT drop it because synthetic sender != agent).
BUS_TAIL="$ROOT/scripts/wow-process/bus-tail.sh"
# Cursor must be 0 to scan from the start of the bus.
mkdir -p "$P4/implementations/.agents"
rm -f "$P4/implementations/.agents/${AGENT_ID}.bus-tail-cursor"
echo "0" > "$P4/implementations/.agents/${AGENT_ID}.bus-tail-cursor"
TAIL_OUT=$(mktemp)
BUS_TAIL_POLL_MS=100 WOW_ROOT="$P4" bash "$BUS_TAIL" \
  "$P4/implementations/.message-bus.jsonl" "$AGENT_ID" "manager" > "$TAIL_OUT" 2>/dev/null &
TAIL_PID=$!
sleep 1
kill -TERM "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true
TAIL_CONTENTS=$(cat "$TAIL_OUT")
assert_contains "case-4-bus-tail-forwards-line" "compaction-occurred" "$TAIL_CONTENTS"
rm -rf "$P4" "$TAIL_OUT"

# -----------------------------------------------------------------------------
# Case 5: post-compact-restore.sh ALIVE — pidfile + live PID → ALIVE line.
# Use our own shell's PID (we know it's alive).
# -----------------------------------------------------------------------------
P5=$(mk_project)
echo "manager" > "$P5/.claude-plugin/current-role"
echo "$$" > "$P5/implementations/.wow-process/bus-tail-manager.pid"
OUT5=$(WOW_ROOT="$P5" bash "$HELPER" 2>/dev/null)
assert_contains "case-5-helper-alive-line" "ALIVE bus-tail $$" "$OUT5"
rm -rf "$P5"

# -----------------------------------------------------------------------------
# Case 6: post-compact-restore.sh MISSING — no pidfile → MISSING line.
# -----------------------------------------------------------------------------
P6=$(mk_project)
echo "manager" > "$P6/.claude-plugin/current-role"
OUT6=$(WOW_ROOT="$P6" bash "$HELPER" 2>/dev/null)
assert_contains "case-6-helper-missing-line" "MISSING bus-tail" "$OUT6"
rm -rf "$P6"

# -----------------------------------------------------------------------------
# Case 7: post-compact-restore.sh STALE — pidfile but dead PID → MISSING.
# Use a very high PID that's almost certainly dead.
# -----------------------------------------------------------------------------
P7=$(mk_project)
echo "manager" > "$P7/.claude-plugin/current-role"
echo "999999" > "$P7/implementations/.wow-process/bus-tail-manager.pid"
OUT7=$(WOW_ROOT="$P7" bash "$HELPER" 2>/dev/null)
assert_contains "case-7-helper-stale-treated-as-missing" "MISSING bus-tail" "$OUT7"
rm -rf "$P7"

# -----------------------------------------------------------------------------
# Case 8: role-process-map.json absent → exit 2 with stderr.
# -----------------------------------------------------------------------------
P8=$(mk_project)
rm -f "$P8/scripts/wow-process/role-process-map.json"
echo "manager" > "$P8/.claude-plugin/current-role"
# Also need to neutralize plugin-cache fallback: set CLAUDE_CONFIG_DIR to a
# dir that doesn't have a plugin cache.
EMPTY_CACHE=$(mktemp -d)
set +e
ERR8=$(WOW_ROOT="$P8" CLAUDE_CONFIG_DIR="$EMPTY_CACHE" bash "$HELPER" 2>&1 >/dev/null)
EXIT8=$?
set -e 2>/dev/null || true
assert_eq "case-8-helper-no-map-exit-2" "2" "$EXIT8"
assert_contains "case-8-helper-no-map-stderr" "role-process-map.json not found" "$ERR8"
rm -rf "$P8" "$EMPTY_CACHE"

# -----------------------------------------------------------------------------
# Case 9: Per-role PID-naming regression — helper looks for
# `${PURPOSE}-${ROLE}.pid`, NOT `${PURPOSE}.pid` (Story 071 PP-FINDING-9).
# Place a live PID at the OLD path; helper should still report MISSING.
# -----------------------------------------------------------------------------
P9=$(mk_project)
echo "manager" > "$P9/.claude-plugin/current-role"
echo "$$" > "$P9/implementations/.wow-process/bus-tail.pid"   # OLD naming
OUT9=$(WOW_ROOT="$P9" bash "$HELPER" 2>/dev/null)
assert_contains "case-9-helper-ignores-old-naming" "MISSING bus-tail" "$OUT9"
rm -rf "$P9"

# -----------------------------------------------------------------------------
# Case 10 (Story 076): post-compact-restore.sh recognizes idle-monitor as a
# manager purpose. With no pidfile → MISSING idle-monitor in the output.
# -----------------------------------------------------------------------------
P10=$(mk_project)
echo "manager" > "$P10/.claude-plugin/current-role"
OUT10=$(WOW_ROOT="$P10" bash "$HELPER" 2>/dev/null)
assert_contains "case-10-idle-monitor-missing" "MISSING idle-monitor" "$OUT10"
rm -rf "$P10"

# -----------------------------------------------------------------------------
# Case 11 (Story 076): pidfile at .wow-process/idle-monitor-manager.pid with
# a live PID → ALIVE idle-monitor <pid> in the helper output.
# -----------------------------------------------------------------------------
P11=$(mk_project)
echo "manager" > "$P11/.claude-plugin/current-role"
echo "$$" > "$P11/implementations/.wow-process/idle-monitor-manager.pid"
OUT11=$(WOW_ROOT="$P11" bash "$HELPER" 2>/dev/null)
assert_contains "case-11-idle-monitor-alive" "ALIVE idle-monitor $$" "$OUT11"
rm -rf "$P11"

# -----------------------------------------------------------------------------
# Case 12 (Story 076): legacy `manager-monitor` purpose should NOT be reported
# by the helper — the role-process-map.json no longer lists it.
# -----------------------------------------------------------------------------
P12=$(mk_project)
echo "manager" > "$P12/.claude-plugin/current-role"
OUT12=$(WOW_ROOT="$P12" bash "$HELPER" 2>/dev/null)
case "$OUT12" in
  *manager-monitor*)
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case-12-no-legacy-manager-monitor-line (output contained 'manager-monitor': $OUT12)")
    ;;
  *)
    PASS=$((PASS+1))
    ;;
esac
rm -rf "$P12"

echo "post-compact-process-restore: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
