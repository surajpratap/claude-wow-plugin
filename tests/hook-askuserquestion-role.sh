#!/usr/bin/env bash
# Story 048 — PreToolUse hook test for AskUserQuestion enforcement.
#
# Invokes scripts/hooks/check-askuserquestion-role.sh in a subshell with
# overridden $PPID + $CLAUDE_PROJECT_DIR (synthetic fixture). Asserts:
#  - manager marker → exit 0, no stderr
#  - peer marker → exit 2 + peer-routing stderr
#  - missing marker → exit 2 + self-recovery stderr
#  - malformed marker (gibberish) → exit 2 + investigate stderr
#  - empty marker → exit 2 + investigate stderr
#  - whitespace-padded marker (manager) → exit 0 (trim works)
#  - stdin payload tolerated (any JSON or none)

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

# Resolve hook script.
HOOK="$(cd "$(dirname "$0")/.." && pwd)/scripts/hooks/check-askuserquestion-role.sh"
[ -x "$HOOK" ] || { echo "FATAL: $HOOK not found or not executable"; exit 2; }

# Helper: invoke hook in a subshell that exec-replaces its own $$ to a fixed PID
# (so the hook reads the desired $PPID). Use bash subprocess substitution.
# Approach: use bash -c with PPID overridden via env-flag (not directly settable
# in modern bash — instead, fake the marker filename via patched hook). Simpler
# approach used: invoke hook from a child-bash whose PPID we know (current bash's
# $$), and write the marker keyed to that PPID.
invoke_hook() {
  local fixture_dir="$1" stdin_input="$2"
  # Direct invocation: bash subprocess's $PPID == current shell's $$.
  # The pipe prefix would create a subshell that breaks the PPID chain;
  # so use a temp file for stdin instead.
  local tmp_stdin; tmp_stdin=$(mktemp)
  printf '%s' "$stdin_input" > "$tmp_stdin"
  CLAUDE_PROJECT_DIR="$fixture_dir" bash "$HOOK" < "$tmp_stdin"
  local rc=$?
  rm -f "$tmp_stdin"
  return $rc
}

# Case 1: manager marker → allow.
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude/.session-role-by-claude-pid"
PPID_HERE=$$
printf '%s\n' "manager" > "$DIR/.claude/.session-role-by-claude-pid/$PPID_HERE"
STDERR_FILE=$(mktemp)
invoke_hook "$DIR" "" 2>"$STDERR_FILE"
RC=$?
assert_eq "case-1-manager-rc" "0" "$RC"
STDERR_LEN=$(wc -c < "$STDERR_FILE" | tr -d ' ')
assert_eq "case-1-manager-no-stderr" "0" "$STDERR_LEN"
rm -rf "$DIR" "$STDERR_FILE"

# Case 2: peer marker → deny + peer-routing message.
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude/.session-role-by-claude-pid"
printf '%s\n' "senior-developer" > "$DIR/.claude/.session-role-by-claude-pid/$PPID_HERE"
STDERR_FILE=$(mktemp)
invoke_hook "$DIR" "" 2>"$STDERR_FILE"
RC=$?
assert_eq "case-2-peer-rc" "2" "$RC"
grep -q "peers route human-facing questions through M via bus" "$STDERR_FILE" && PASS_ROUTING="yes" || PASS_ROUTING="no"
assert_eq "case-2-peer-routing-msg" "yes" "$PASS_ROUTING"
rm -rf "$DIR" "$STDERR_FILE"

# Case 3: missing marker → deny + self-recovery message.
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude/.session-role-by-claude-pid"
# no marker for our PPID
STDERR_FILE=$(mktemp)
invoke_hook "$DIR" "" 2>"$STDERR_FILE"
RC=$?
assert_eq "case-3-missing-rc" "2" "$RC"
grep -q "cannot determine session role" "$STDERR_FILE" && SELF_RECOVERY="yes" || SELF_RECOVERY="no"
assert_eq "case-3-self-recovery-msg" "yes" "$SELF_RECOVERY"
grep -q "If you are M, write 'manager'" "$STDERR_FILE" && M_HINT="yes" || M_HINT="no"
assert_eq "case-3-m-hint-msg" "yes" "$M_HINT"
rm -rf "$DIR" "$STDERR_FILE"

# Case 4: malformed marker (gibberish role) → deny + investigate message.
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude/.session-role-by-claude-pid"
printf '%s\n' "gobbledygook" > "$DIR/.claude/.session-role-by-claude-pid/$PPID_HERE"
STDERR_FILE=$(mktemp)
invoke_hook "$DIR" "" 2>"$STDERR_FILE"
RC=$?
assert_eq "case-4-gibberish-rc" "2" "$RC"
grep -q "unrecognized role" "$STDERR_FILE" && INVESTIGATE="yes" || INVESTIGATE="no"
assert_eq "case-4-investigate-msg" "yes" "$INVESTIGATE"
rm -rf "$DIR" "$STDERR_FILE"

# Case 5: malformed marker (empty file) → deny + unrecognized.
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude/.session-role-by-claude-pid"
: > "$DIR/.claude/.session-role-by-claude-pid/$PPID_HERE"
STDERR_FILE=$(mktemp)
invoke_hook "$DIR" "" 2>"$STDERR_FILE"
RC=$?
assert_eq "case-5-empty-rc" "2" "$RC"
grep -q "unrecognized role" "$STDERR_FILE" && EMPTY_INV="yes" || EMPTY_INV="no"
assert_eq "case-5-empty-investigate" "yes" "$EMPTY_INV"
rm -rf "$DIR" "$STDERR_FILE"

# Case 6: whitespace-padded valid role → trim succeeds → allow.
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude/.session-role-by-claude-pid"
printf '%s\n' "  manager  " > "$DIR/.claude/.session-role-by-claude-pid/$PPID_HERE"
STDERR_FILE=$(mktemp)
invoke_hook "$DIR" "" 2>"$STDERR_FILE"
RC=$?
assert_eq "case-6-whitespace-trim-allow" "0" "$RC"
rm -rf "$DIR" "$STDERR_FILE"

# Case 7: stdin payload tolerated (any JSON or none).
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude/.session-role-by-claude-pid"
printf '%s\n' "manager" > "$DIR/.claude/.session-role-by-claude-pid/$PPID_HERE"
STDERR_FILE=$(mktemp)
invoke_hook "$DIR" '{"session_id":"abc","cwd":"/x"}' 2>"$STDERR_FILE"
RC=$?
assert_eq "case-7a-stdin-json-tolerated" "0" "$RC"
rm -f "$STDERR_FILE"

# Empty stdin
STDERR_FILE=$(mktemp)
invoke_hook "$DIR" "" 2>"$STDERR_FILE"
RC=$?
assert_eq "case-7b-empty-stdin-tolerated" "0" "$RC"
rm -rf "$DIR" "$STDERR_FILE"

# Case 8: each peer role triggers the same routing message (parameterized).
for peer_role in pair-programmer tester slacker; do
  DIR=$(mktemp -d)
  mkdir -p "$DIR/.claude/.session-role-by-claude-pid"
  printf '%s\n' "$peer_role" > "$DIR/.claude/.session-role-by-claude-pid/$PPID_HERE"
  STDERR_FILE=$(mktemp)
  invoke_hook "$DIR" "" 2>"$STDERR_FILE"
  RC=$?
  assert_eq "case-8-${peer_role}-rc" "2" "$RC"
  grep -q "peers route human-facing questions through M via bus" "$STDERR_FILE" && OK="yes" || OK="no"
  assert_eq "case-8-${peer_role}-routing-msg" "yes" "$OK"
  rm -rf "$DIR" "$STDERR_FILE"
done

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "hook-askuserquestion-role: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
