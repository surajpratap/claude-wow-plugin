#!/usr/bin/env bash
# Bug 0003 FINDING-43 (MAJOR) regression guard.
# v3.29.0's verify_monitors() iterated tracker's *_task_id fields. On
# a fresh tracker with zero such keys, the loop ran zero times, missing
# stayed 0, return 0. Agents passed `--verify` with NO Monitors armed.
#
# Story 161 reads role-process-map.json, computes required purposes
# (stripping ?-optional + filtering github-bridge by config presence),
# and rejects when tracker_task_id_count == 0 AND required != [].

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

REAL_WOW_LOCATE=$(command -v wow-locate 2>/dev/null || true)
if [ -z "$REAL_WOW_LOCATE" ]; then
  echo "SKIP: wow-locate not on PATH" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations/.agents" "$PROJ/implementations/.wow-process"

# Role marker — drives whats-my-role.sh detection
echo "$$" > "$PROJ/implementations/.agents/senior-developer.role-claim"

# Fresh tracker — no *_task_id keys yet
TS=$(date -u +%Y%m%dT%H%M%S)
AGENT_ID="senior-developer-$TS-aaaaaa"
TRACKER="$PROJ/implementations/.agents/${AGENT_ID}.json"
jq -nc '{last_line: 0, last_seen: "2026-05-29T00:00:00Z", claude_pid: 0}' > "$TRACKER"

# Stub whats-my-role.sh to print senior-developer (deterministic role)
STUB=$(mktemp -d)
cat > "$STUB/wow-locate" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "scripts/whats-my-role.sh" ]; then
  echo "$STUB/whats-my-role.sh"
  exit 0
fi
exec "$REAL_WOW_LOCATE" "\$@"
EOF
chmod +x "$STUB/wow-locate"

cat > "$STUB/whats-my-role.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "whats-my-role" ]; then
  echo "senior-developer"
fi
EOF
chmod +x "$STUB/whats-my-role.sh"

# Case 1: fresh tracker + role with required Monitors → non-zero + EXIT_NO_MONITORS_ARMED
OUT_ERR=$(WOW_ROOT="$PROJ" PATH="$STUB:$PATH" bash "$STARTUP" --verify 2>&1 1>/dev/null)
RC=$?
assert_eq "case1: fresh tracker → exit non-zero" "1" "$RC"

if printf '%s' "$OUT_ERR" | grep -q "EXIT_NO_MONITORS_ARMED"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case1: stderr should contain EXIT_NO_MONITORS_ARMED (got: $OUT_ERR)")
fi

if printf '%s' "$OUT_ERR" | grep -q "senior-developer"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case1: stderr should name role 'senior-developer'")
fi

if printf '%s' "$OUT_ERR" | grep -q "bus-tail"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case1: stderr should list expected 'bus-tail' purpose")
fi

# Case 2: tracker with bus-tail_task_id + live PID file → exit 0
jq '. + {bus_tail_task_id: "fake-task-id-1"}' "$TRACKER" > "${TRACKER}.tmp" && mv "${TRACKER}.tmp" "$TRACKER"
echo $$ > "$PROJ/implementations/.wow-process/bus-tail-senior-developer.pid"

OUT_ERR=$(WOW_ROOT="$PROJ" PATH="$STUB:$PATH" bash "$STARTUP" --verify 2>&1 1>/dev/null)
RC=$?
assert_eq "case2: armed tracker + live PID → exit 0" "0" "$RC"

# Case 3: tracker has task_id key but PID file missing → exit 1 (legacy behavior preserved)
rm -f "$PROJ/implementations/.wow-process/bus-tail-senior-developer.pid"
OUT_ERR=$(WOW_ROOT="$PROJ" PATH="$STUB:$PATH" bash "$STARTUP" --verify 2>&1 1>/dev/null)
RC=$?
assert_eq "case3: armed tracker but PID gone → exit non-zero (EXIT_MISSING_MONITOR)" "1" "$RC"
if printf '%s' "$OUT_ERR" | grep -q "EXIT_MISSING_MONITOR"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case3: stderr should contain EXIT_MISSING_MONITOR (legacy path)")
fi

rm -rf "$PROJ" "$STUB"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
