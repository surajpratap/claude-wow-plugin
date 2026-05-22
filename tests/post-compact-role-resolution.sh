#!/usr/bin/env bash
# Story 133 (FINDING-35) — post-compact pair (`post-compact-rearm-verify.sh`
# + `post-compact-restore.sh`) resolve the role via `whats-my-role.sh`, NOT
# a fixed `${WOW_ROOT}/.claude-plugin/current-role` path that nothing writes.
#
# Pre-fix, both scripts exited 3 on every run; Story 099 wake-loop
# self-check + Story 105 post-compact verify were silently inert. This test
# pins the new resolution + locks out the bug shape.
#
# Note: a live "happy path" test (claim role → run script → assert past
# gate) would require simulating a claude-process ancestry that the helper's
# `wow_find_claude_pid` PPID-walk recognizes — impractical from a bash test
# whose grandparent is `run-all.sh`. Instead we pin (1) the static shape of
# the fix and (2) the NEW error message on the no-marker path, which would
# differ from the pre-fix message if anyone reverts.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

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
REARM="$ROOT/scripts/wow-process/post-compact-rearm-verify.sh"
RESTORE="$ROOT/scripts/wow-process/post-compact-restore.sh"

# ---- (a) rearm-verify body: helper invocation present ----
REARM_BODY=$(cat "$REARM")
assert_contains "a-rearm-verify-invokes-helper" \
  'bash "$WMR" whats-my-role' "$REARM_BODY"

# ---- (b) restore body: same helper invocation ----
RESTORE_BODY=$(cat "$RESTORE")
assert_contains "b-restore-invokes-helper" \
  'bash "$WMR" whats-my-role' "$RESTORE_BODY"

# ---- (c) anti-revert: dead `.claude-plugin/current-role` path assignment gone ----
# FINDING-36: PP found 3 more scripts with the IDENTICAL bug class
# (monitor-rearm-record.sh:19, monitor-spec.sh:26, tracker-armed-purposes.sh:15).
# Pin the bug-shape literal — the assignment `ROLE_MARKER=...` reading the
# dead path — across ALL plugin/scripts/wow-process/*.sh. Prose comments
# mentioning the path are fine (the Story 133 comment explaining the fix
# has to name it); only the live code shape is the anti-revert target.
WOW_PROCESS_SCRIPTS="$ROOT/scripts/wow-process"
FOUND_DEAD_PATH=0
for s in "$WOW_PROCESS_SCRIPTS"/*.sh; do
  if grep -q 'ROLE_MARKER="\${WOW_ROOT}/.claude-plugin/current-role"' "$s"; then
    FOUND_DEAD_PATH=1
    FAIL=$((FAIL+1))
    FAILED_CASES+=("c-dead-ROLE_MARKER-assignment-in-$(basename "$s")")
  fi
done
if [ "$FOUND_DEAD_PATH" -eq 0 ]; then
  PASS=$((PASS+1))
fi

# ---- (d) runtime: no-marker error message names the NEW location ----
# Use an isolated WOW_ROOT with no marker; the helper's PPID-walk won't find
# claude in this test's ancestry, so whats-my-role returns empty → exit 3.
# The NEW error message mentions `.session-role-by-claude-pid`; the OLD one
# mentioned `.claude-plugin/current-role`. We assert the new shape.
D=$(mktemp -d)
mkdir -p "$D/.claude-plugin" "$D/implementations"
echo '{"name":"x","version":"0.0.0"}' > "$D/.claude-plugin/plugin.json"

ERR_REARM=$(WOW_ROOT="$D" bash "$REARM" 2>&1 1>/dev/null || true)
RC_REARM=$(WOW_ROOT="$D" bash "$REARM" >/dev/null 2>&1; echo $?)
assert_eq "d-rearm-no-marker-exits-3" "3" "$RC_REARM"
assert_contains "d-rearm-new-error-message" \
  ".session-role-by-claude-pid" "$ERR_REARM"
assert_not_contains "d-rearm-no-old-error-message" \
  ".claude-plugin/current-role" "$ERR_REARM"

# ---- (e) same runtime check for restore ----
ERR_RESTORE=$(WOW_ROOT="$D" bash "$RESTORE" 2>&1 1>/dev/null || true)
RC_RESTORE=$(WOW_ROOT="$D" bash "$RESTORE" >/dev/null 2>&1; echo $?)
assert_eq "e-restore-no-marker-exits-3" "3" "$RC_RESTORE"
assert_contains "e-restore-new-error-message" \
  ".session-role-by-claude-pid" "$ERR_RESTORE"
assert_not_contains "e-restore-no-old-error-message" \
  ".claude-plugin/current-role" "$ERR_RESTORE"

rm -rf "$D"

echo "post-compact-role-resolution: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
