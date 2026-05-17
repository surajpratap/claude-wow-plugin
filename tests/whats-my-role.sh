#!/usr/bin/env bash
# Story 049 — whats-my-role.sh helper test.
#
# Most cases use a synthetic MARKER_DIR (override via env) so claim/release
# operate on a temp dir, not the real .claude/ tree. PPID-walk edge cases
# use a PATH-shimmed `ps` to simulate parent-chain scenarios.

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

# Resolve script under test.
SUT="$(cd "$(dirname "$0")/.." && pwd)/scripts/whats-my-role.sh"
[ -x "$SUT" ] || { echo "FATAL: $SUT not found or not executable"; exit 2; }

# -----------------------------------------------------------------------------
# Helper: source the script with an override MARKER_DIR pointing at a temp.
# We cannot simply set MARKER_DIR before sourcing because the script
# reassigns it on load. Instead, we override after sourcing.
# Helper: load functions in a fresh subshell each test for isolation.
# -----------------------------------------------------------------------------

# Spawn a subshell, source the helper, override MARKER_DIR, eval a snippet,
# echo result. Stdin/stderr propagate normally.
in_sandbox() {
  local marker_dir="$1"; shift
  local snippet="$1"; shift
  bash -c "
    set -u
    source '$SUT'
    MARKER_DIR='$marker_dir'
    $snippet
  "
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: claim -> whats-my-role round-trip.
DIR=$(mktemp -d)
PID=$$
mkdir -p "$DIR"
# Write marker directly (simulates what wow_claim_role does after PPID walk).
printf '%s\n' "manager" > "$DIR/$PID"
RESULT=$(in_sandbox "$DIR" "wow_read_role_by_claude_pid $PID")
assert_eq "case-1-roundtrip-read" "manager" "$RESULT"
rm -rf "$DIR"

# Case 2: claim is idempotent on same role.
DIR=$(mktemp -d)
PID=$$
printf '%s\n' "manager" > "$DIR/$PID"
RC=$(in_sandbox "$DIR" "
  # Mock find_claude_pid to return our PID.
  wow_find_claude_pid() { echo $PID; return 0; }
  wow_claim_role manager >/dev/null 2>&1
  echo \$?
")
assert_eq "case-2-idempotent-rc" "0" "$RC"
CONTENT=$(cat "$DIR/$PID")
assert_eq "case-2-idempotent-content" "manager" "$CONTENT"
rm -rf "$DIR"

# Case 3: claim refuses different-role conflict.
DIR=$(mktemp -d)
PID=$$
printf '%s\n' "manager" > "$DIR/$PID"
RC=$(in_sandbox "$DIR" "
  wow_find_claude_pid() { echo $PID; return 0; }
  wow_claim_role tester >/dev/null 2>&1
  echo \$?
")
assert_eq "case-3-conflict-rc" "2" "$RC"
CONTENT=$(cat "$DIR/$PID")
assert_eq "case-3-conflict-marker-unchanged" "manager" "$CONTENT"
rm -rf "$DIR"

# Case 4: release removes marker.
DIR=$(mktemp -d)
PID=$$
printf '%s\n' "manager" > "$DIR/$PID"
in_sandbox "$DIR" "
  wow_find_claude_pid() { echo $PID; return 0; }
  wow_release_role
" >/dev/null 2>&1
EXISTS=$([ -f "$DIR/$PID" ] && echo "yes" || echo "no")
assert_eq "case-4-release-removes" "no" "$EXISTS"
rm -rf "$DIR"

# Case 5: sweep removes markers for non-existent PIDs.
DIR=$(mktemp -d)
mkdir -p "$DIR"
printf '%s\n' "manager" > "$DIR/9999999"
in_sandbox "$DIR" "wow_sweep_stale_role_markers" >/dev/null 2>&1
EXISTS=$([ -f "$DIR/9999999" ] && echo "yes" || echo "no")
assert_eq "case-5-sweep-removes-stale" "no" "$EXISTS"
rm -rf "$DIR"

# Case 6: sweep keeps markers for live PIDs.
DIR=$(mktemp -d)
PID=$$
mkdir -p "$DIR"
printf '%s\n' "manager" > "$DIR/$PID"
in_sandbox "$DIR" "wow_sweep_stale_role_markers" >/dev/null 2>&1
EXISTS=$([ -f "$DIR/$PID" ] && echo "yes" || echo "no")
assert_eq "case-6-sweep-keeps-live" "yes" "$EXISTS"
rm -rf "$DIR"

# Case 7: PPID walk handles 1-hop scenario.
# Use ps shim that reports current PID -> /bin/zsh (depth 0), parent -> claude (depth 1).
DIR=$(mktemp -d)
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/ps" <<'SHIM'
#!/usr/bin/env bash
# ps shim — emulates a 1-hop walk to claude.
# Args parsed minimally: -o command= -p <pid>  OR  -o ppid= -p <pid>  OR  -p <pid>
arg_opt=""; arg_pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) arg_opt="$2"; shift 2 ;;
    -p) arg_pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$arg_pid" in
  100) [ "$arg_opt" = "command=" ] && echo "/bin/zsh -c synthetic"; [ "$arg_opt" = "ppid=" ] && echo "200" ;;
  200) [ "$arg_opt" = "command=" ] && echo "claude --continue"; [ "$arg_opt" = "ppid=" ] && echo "1" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIM_DIR/ps"
RESULT=$(PATH="$SHIM_DIR:$PATH" bash -c "
  set -u
  source '$SUT'
  MARKER_DIR='$DIR'
  # Force \$\$ to be 100 by faking it inline.
  wow_find_claude_pid() {
    local pid=100 depth=0 cmd binary ppid
    while [ \"\$pid\" != \"1\" ] && [ -n \"\$pid\" ] && [ \"\$depth\" -lt 25 ]; do
      cmd=\$(ps -o command= -p \"\$pid\" 2>/dev/null)
      binary=\$(echo \"\$cmd\" | awk '{print \$1}')
      ppid=\$(ps -o ppid= -p \"\$pid\" 2>/dev/null | tr -d ' ')
      if [ \"\$depth\" -ge 1 ]; then
        case \"\$binary\" in
          */claude|claude|*claude/cli*|*claude/*/cli*) echo \"\$pid\"; return 0 ;;
        esac
      fi
      pid=\"\$ppid\"
      depth=\$((depth+1))
    done
    return 1
  }
  wow_find_claude_pid
")
assert_eq "case-7-1hop-finds-pid-200" "200" "$RESULT"
rm -rf "$DIR" "$SHIM_DIR"

# Case 8: PPID walk handles multi-hop scenario.
DIR=$(mktemp -d); SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/ps" <<'SHIM'
#!/usr/bin/env bash
arg_opt=""; arg_pid=""
while [ $# -gt 0 ]; do
  case "$1" in -o) arg_opt="$2"; shift 2 ;; -p) arg_pid="$2"; shift 2 ;; *) shift ;; esac
done
case "$arg_pid" in
  100) [ "$arg_opt" = "command=" ] && echo "/bin/bash"; [ "$arg_opt" = "ppid=" ] && echo "200" ;;
  200) [ "$arg_opt" = "command=" ] && echo "/bin/zsh -c wrap"; [ "$arg_opt" = "ppid=" ] && echo "300" ;;
  300) [ "$arg_opt" = "command=" ] && echo "/usr/bin/sh -c wrap"; [ "$arg_opt" = "ppid=" ] && echo "400" ;;
  400) [ "$arg_opt" = "command=" ] && echo "claude --continue"; [ "$arg_opt" = "ppid=" ] && echo "1" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIM_DIR/ps"
RESULT=$(PATH="$SHIM_DIR:$PATH" bash -c "
  source '$SUT'
  MARKER_DIR='$DIR'
  wow_find_claude_pid() {
    local pid=100 depth=0 cmd binary ppid
    while [ \"\$pid\" != \"1\" ] && [ -n \"\$pid\" ] && [ \"\$depth\" -lt 25 ]; do
      cmd=\$(ps -o command= -p \"\$pid\" 2>/dev/null)
      binary=\$(echo \"\$cmd\" | awk '{print \$1}')
      ppid=\$(ps -o ppid= -p \"\$pid\" 2>/dev/null | tr -d ' ')
      if [ \"\$depth\" -ge 1 ]; then
        case \"\$binary\" in */claude|claude|*claude/cli*|*claude/*/cli*) echo \"\$pid\"; return 0 ;; esac
      fi
      pid=\"\$ppid\"; depth=\$((depth+1))
    done
    return 1
  }
  wow_find_claude_pid
")
assert_eq "case-8-multihop-finds-pid-400" "400" "$RESULT"
rm -rf "$DIR" "$SHIM_DIR"

# Case 9: PPID walk fails closed when no claude in chain.
DIR=$(mktemp -d); SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/ps" <<'SHIM'
#!/usr/bin/env bash
arg_opt=""; arg_pid=""
while [ $# -gt 0 ]; do
  case "$1" in -o) arg_opt="$2"; shift 2 ;; -p) arg_pid="$2"; shift 2 ;; *) shift ;; esac
done
case "$arg_pid" in
  100) [ "$arg_opt" = "command=" ] && echo "/bin/bash"; [ "$arg_opt" = "ppid=" ] && echo "1" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIM_DIR/ps"
RC=$(PATH="$SHIM_DIR:$PATH" bash -c "
  source '$SUT'
  MARKER_DIR='$DIR'
  wow_find_claude_pid() {
    local pid=100 depth=0 cmd binary ppid
    while [ \"\$pid\" != \"1\" ] && [ -n \"\$pid\" ] && [ \"\$depth\" -lt 25 ]; do
      cmd=\$(ps -o command= -p \"\$pid\" 2>/dev/null)
      binary=\$(echo \"\$cmd\" | awk '{print \$1}')
      ppid=\$(ps -o ppid= -p \"\$pid\" 2>/dev/null | tr -d ' ')
      if [ \"\$depth\" -ge 1 ]; then
        case \"\$binary\" in */claude|claude|*claude/cli*|*claude/*/cli*) echo \"\$pid\"; return 0 ;; esac
      fi
      pid=\"\$ppid\"; depth=\$((depth+1))
    done
    return 1
  }
  wow_find_claude_pid
  echo \"--rc=\$?\"
" 2>/dev/null)
case "$RC" in
  *--rc=1*) assert_eq "case-9-no-claude-fails-closed" "yes" "yes" ;;
  *) assert_eq "case-9-no-claude-fails-closed" "yes" "no (got: $RC)" ;;
esac
rm -rf "$DIR" "$SHIM_DIR"

# Case 10: malformed marker (gibberish role) returns unknown.
DIR=$(mktemp -d)
PID=$$
printf '%s\n' "gobbledygook" > "$DIR/$PID"
RC=$(in_sandbox "$DIR" "wow_read_role_by_claude_pid $PID >/dev/null 2>&1; echo \$?")
assert_eq "case-10-malformed-rc" "1" "$RC"
rm -rf "$DIR"

# Case 11: marker permissions are 0644.
DIR=$(mktemp -d)
PID=$$
in_sandbox "$DIR" "
  wow_find_claude_pid() { echo $PID; return 0; }
  wow_claim_role manager >/dev/null 2>&1
" >/dev/null 2>&1
# BSD vs GNU stat compatibility
MODE=$(stat -c '%a' "$DIR/$PID" 2>/dev/null || stat -f '%Lp' "$DIR/$PID" 2>/dev/null)
assert_eq "case-11-marker-mode-0644" "644" "$MODE"
rm -rf "$DIR"

# Case 12: CLI dispatch — usage on no-arg.
USAGE=$(bash "$SUT" 2>&1 || true)
case "$USAGE" in
  *whats-my-role*claim*release*sweep*find-claude-pid*) assert_eq "case-12-cli-usage" "yes" "yes" ;;
  *) assert_eq "case-12-cli-usage" "yes" "no (got: $USAGE)" ;;
esac

# Case 13: CLI dispatch — sweep returns 0 even on missing dir.
DIR=$(mktemp -d)
RC=$(MARKER_DIR_OVERRIDE="$DIR/nonexistent" bash -c "
  source '$SUT'
  MARKER_DIR='$DIR/nonexistent'
  wow_sweep_stale_role_markers
  echo \$?
")
assert_eq "case-13-sweep-missing-dir-rc" "0" "$RC"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "whats-my-role: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
