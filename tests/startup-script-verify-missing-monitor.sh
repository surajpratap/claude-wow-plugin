#!/usr/bin/env bash
# Story 152 — --verify mode exits non-zero with EXIT_MISSING_MONITOR
# <purpose> <re-arm-spec-JSON> on stderr for any tracker-recorded
# Monitor whose corresponding PID is not alive (kill -0 fails).

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

# Path to the real wow-locate (so the override can delegate to it
# without recursion).
REAL_WOW_LOCATE=$(command -v wow-locate)

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations/.agents" "$PROJ/implementations/.wow-process"

# Case 1: --verify with no live role marker exits 3 (role marker missing)
OUT=$(WOW_ROOT="$PROJ" bash "$STARTUP" --verify 2>&1)
RC=$?
case "$RC" in
  1|3) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); FAILED_CASES+=("case1: --verify with no live role marker should exit 1 or 3 (got $RC)") ;;
esac

# Case 2: --verify with tracker recording a task-id + dead PID file -> exit 1 + EXIT_MISSING_MONITOR on stderr
# Synthetic tracker
SD_ID="senior-developer-20260528T120000-deadbe"
cat > "$PROJ/implementations/.agents/${SD_ID}.json" <<EOF
{"last_line": 0, "last_seen": "2026-05-28T12:00:00Z", "claude_pid": $$, "bus_tail_task_id": "abc123"}
EOF
echo "999999" > "$PROJ/implementations/.wow-process/bus-tail-senior-developer.pid"

# Override wow-locate to return a stub whats-my-role.sh for the role
# lookup; delegate other paths to the real wow-locate.
PATH_OVERRIDE=$(mktemp -d)
WMR_PATH="$PROJ/whats-my-role-stub.sh"
cat > "$WMR_PATH" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  whats-my-role) echo "senior-developer" ;;
esac
EOF
chmod +x "$WMR_PATH"

cat > "$PATH_OVERRIDE/wow-locate" <<EOF
#!/usr/bin/env bash
case "\$1" in
  scripts/whats-my-role.sh) echo "$WMR_PATH" ;;
  *) exec "$REAL_WOW_LOCATE" "\$@" ;;
esac
EOF
chmod +x "$PATH_OVERRIDE/wow-locate"

STDERR=$(PATH="$PATH_OVERRIDE:$PATH" WOW_ROOT="$PROJ" bash "$STARTUP" --verify 2>&1 >/dev/null)
RC2=$?
assert_eq "case2: --verify with dead PID exits 1" "1" "$RC2"
if printf '%s' "$STDERR" | grep -q "EXIT_MISSING_MONITOR.*bus-tail"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case2: stderr missing EXIT_MISSING_MONITOR bus-tail (got: $STDERR)")
fi

# Case 3: --verify with tracker recording a task-id + live PID -> exit 0
LIVE_PID=$$
echo "$LIVE_PID" > "$PROJ/implementations/.wow-process/bus-tail-senior-developer.pid"
PATH="$PATH_OVERRIDE:$PATH" WOW_ROOT="$PROJ" bash "$STARTUP" --verify 2>&1 >/dev/null
RC3=$?
assert_eq "case3: --verify with live PID exits 0" "0" "$RC3"

rm -rf "$PROJ" "$PATH_OVERRIDE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
