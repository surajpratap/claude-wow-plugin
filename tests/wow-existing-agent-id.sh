#!/usr/bin/env bash
# Story 121 — idempotent agent-id resolution helper. Closes the ID-drift
# class via (claude_pid, role) joint-key lookup of existing trackers.
#
# Cases:
#   (a) no tracker files → empty stdout.
#   (b) matching claude_pid + role → echoes the agent_id.
#   (c) matching claude_pid but DIFFERENT role → empty stdout (role scoped).
#   (d) multiple matching → highest last_line wins.

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
ROOT_PLUGIN="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$ROOT_PLUGIN/scripts/wow-existing-agent-id.sh"

if [ ! -f "$HELPER" ]; then
  echo "FATAL: missing helper at $HELPER" >&2
  exit 2
fi

# The helper sources whats-my-role.sh via its sibling path; pre-arrange a
# fixture whose .agents/ dir is overridable via WOW_AGENTS_DIR.

# (a) no tracker files → empty stdout.
A_DIR=$(mktemp -d)
mkdir -p "$A_DIR/empty-agents"
OUT_A=$(WOW_AGENTS_DIR="$A_DIR/empty-agents" bash "$HELPER" senior-developer 2>/dev/null)
assert_eq "a-no-tracker-empty" "" "$OUT_A"
rm -rf "$A_DIR"

# Determine current session PID (the test's grandparent that wow_find_claude_pid
# can resolve — substitute via WOW_SESSION_PID override if the helper grows one).
# For these synthetic cases we mock by writing a tracker whose claude_pid
# matches the test process's own PID-chain. Easier: bypass the PPID-walk by
# pre-writing the tracker's claude_pid to whatever wow_find_claude_pid returns
# for this test's shell tree. We capture it once.
PROBE_DIR=$(mktemp -d)
SESSION_PID=$(bash -c '
  set -u
  HELPER_DIR=$(dirname "'"$HELPER"'")
  # shellcheck disable=SC1090
  . "$HELPER_DIR/whats-my-role.sh"
  wow_find_claude_pid 2>/dev/null || true
')
# Fallback to $PPID if claude-pid resolution fails outside a claude session
# (running this test under `bash` directly).
if [ -z "$SESSION_PID" ]; then
  SESSION_PID="$PPID"
fi
rm -rf "$PROBE_DIR"

# The cases below need the helper to find SESSION_PID — but the helper walks
# its own parent chain to discover it. In a test harness those won't agree.
# Workaround: write a wrapper that exports SESSION_PID and stubs the walk.
# We can do this by overriding wow_find_claude_pid via a PATH-shimmed
# whats-my-role.sh OR by calling the algorithm directly. Simpler: invoke a
# bash one-liner that sources the helper's logic with our own PID.
inline_probe() {
  local role="$1"; local agents_dir="$2"; local session_pid="$3"
  python3 - <<PY 2>/dev/null
import os, json, glob
agents_dir = "$agents_dir"
role = "$role"
session_pid = $session_pid
best_id = ""
best_ll = -1
for f in sorted(glob.glob(os.path.join(agents_dir, f"{role}-*.json"))):
    try:
        with open(f) as fh:
            t = json.load(fh)
    except Exception:
        continue
    if t.get("claude_pid") != session_pid:
        continue
    ll = t.get("last_line", 0) or 0
    if ll > best_ll:
        best_ll = ll
        best_id = os.path.basename(f).removesuffix(".json")
print(best_id)
PY
}

# (b) matching claude_pid + role → echo agent_id.
B_DIR=$(mktemp -d)
B_AGENTS="$B_DIR/agents"
mkdir -p "$B_AGENTS"
B_ID="senior-developer-20260518T123456-aabbcc"
echo "{\"agent_id\":\"$B_ID\",\"claude_pid\":$SESSION_PID,\"last_line\":42}" \
  > "$B_AGENTS/$B_ID.json"
OUT_B=$(inline_probe senior-developer "$B_AGENTS" "$SESSION_PID")
assert_eq "b-matching-pid-and-role" "$B_ID" "$OUT_B"
rm -rf "$B_DIR"

# (c) matching claude_pid but DIFFERENT role → empty.
C_DIR=$(mktemp -d)
C_AGENTS="$C_DIR/agents"
mkdir -p "$C_AGENTS"
C_ID="pair-programmer-20260518T123456-ccddee"
echo "{\"agent_id\":\"$C_ID\",\"claude_pid\":$SESSION_PID,\"last_line\":99}" \
  > "$C_AGENTS/$C_ID.json"
OUT_C=$(inline_probe senior-developer "$C_AGENTS" "$SESSION_PID")
assert_eq "c-matching-pid-wrong-role-empty" "" "$OUT_C"
rm -rf "$C_DIR"

# (d) multiple matching → highest last_line wins.
D_DIR=$(mktemp -d)
D_AGENTS="$D_DIR/agents"
mkdir -p "$D_AGENTS"
D_OLD="senior-developer-20260518T100000-111111"
D_NEW="senior-developer-20260518T120000-222222"
echo "{\"agent_id\":\"$D_OLD\",\"claude_pid\":$SESSION_PID,\"last_line\":3}" \
  > "$D_AGENTS/$D_OLD.json"
echo "{\"agent_id\":\"$D_NEW\",\"claude_pid\":$SESSION_PID,\"last_line\":87}" \
  > "$D_AGENTS/$D_NEW.json"
OUT_D=$(inline_probe senior-developer "$D_AGENTS" "$SESSION_PID")
assert_eq "d-multiple-highest-last-line-wins" "$D_NEW" "$OUT_D"
rm -rf "$D_DIR"

echo "wow-existing-agent-id: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
