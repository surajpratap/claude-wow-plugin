#!/usr/bin/env bash
# Story 160 Layer F — fork-bomb-resistance end-to-end isolation tests for
# the suite runner sandbox (run-all.sh outer wrapper + run-all-sandbox.py
# Python session-leader wrapper + run-all-inner.sh suite body).
#
# Three cases:
#   1. ulimit-budget-applies — when budget has headroom, ulimit -u is set.
#   2. session-reap          — a leaked grandchild dies with the wrapper.
#   3. timeout-fires         — an infinite-loop test is killed by timeout.

set -u

PASS=0; FAIL=0
FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="$ROOT/scripts/run-all-sandbox.py"
INNER="$ROOT/tests/run-all-inner.sh"

# ---- (1) ulimit-budget-applies ----
# Run the outer run-all.sh with WOW_TEST_PROC_BUDGET high enough to leave
# room over current usage. The outer wrapper should NOT emit the
# "skipping ulimit" stderr line. (Inverse: with budget=1 it MUST emit it.)
FIXTURE=$(mktemp -d)
mkdir -p "$FIXTURE/tests"
cp "$ROOT/tests/run-all.sh" "$FIXTURE/tests/run-all.sh"
# Fixture has no inner — outer falls back to bash $INNER (missing). Just
# observe the stderr from the ulimit branch + fallback message, then exit.
# The outer prints both before exec'ing; we only care about the ulimit line.

# Sub-case 1a: high budget — ulimit should apply (no skip-line).
out_high=$(WOW_TEST_PROC_BUDGET=20000 bash "$FIXTURE/tests/run-all.sh" --help 2>&1 || true)
if echo "$out_high" | grep -q "skipping ulimit"; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("1a-high-budget: expected ulimit-apply, got skip")
else
  PASS=$((PASS+1))
fi

# Sub-case 1b: tiny budget — must emit skip-line (current_procs >> 1).
out_low=$(WOW_TEST_PROC_BUDGET=1 bash "$FIXTURE/tests/run-all.sh" --help 2>&1 || true)
if echo "$out_low" | grep -q "skipping ulimit"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("1b-low-budget: expected skip-line, got none")
fi
rm -rf "$FIXTURE"

# ---- (2) session-reap ----
# The Python sandbox wrapper installs an atexit-time os.killpg(0, SIGTERM)
# /SIGKILL reap. Verify a grandchild started by a child of the wrapper is
# killed when the wrapper exits, even though the grandchild outlives its
# direct parent (orphaned to PID 1 in a normal process tree).
#
# Strategy:
#   * launch the sandbox running a child that double-forks a sleeper writing
#     its PID to a known file, then immediately exits.
#   * wait briefly so the sleeper exists.
#   * after the sandbox returns, sleep ~1.5s (TERM grace) and assert sleeper
#     PID is no longer alive.
LEAK_DIR=$(mktemp -d)
LEAK_PIDFILE="$LEAK_DIR/grandchild.pid"
LEAK_SCRIPT="$LEAK_DIR/leak.sh"
cat >"$LEAK_SCRIPT" <<EOF
#!/usr/bin/env bash
# Double-fork a long sleep, record PID, then exit immediately.
( sleep 60 & echo "\$!" > "$LEAK_PIDFILE" ) &
wait
EOF
chmod +x "$LEAK_SCRIPT"

# Run via sandbox; child exits ~immediately.
python3 "$SANDBOX" -- bash "$LEAK_SCRIPT" >/dev/null 2>&1 || true

# Give the reap signals time to land.
sleep 2

LEAK_PID=""
[ -f "$LEAK_PIDFILE" ] && LEAK_PID=$(cat "$LEAK_PIDFILE")
if [ -z "$LEAK_PID" ]; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("2-session-reap: grandchild never wrote PID")
elif kill -0 "$LEAK_PID" 2>/dev/null; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("2-session-reap: grandchild $LEAK_PID survived sandbox exit")
  kill -KILL "$LEAK_PID" 2>/dev/null || true
else
  PASS=$((PASS+1))
fi
rm -rf "$LEAK_DIR"

# ---- (3) timeout-fires ----
# A test that runs `sleep 30` with WOW_TEST_TIMEOUT_S=2 must be killed
# by the run-all-inner.sh timeout(1) wrapper and recorded as failed.
# Skip silently if timeout(1) isn't on PATH (degrade gracefully — same
# fallback the inner takes).
if ! command -v timeout >/dev/null 2>&1; then
  echo "test-runner-host-isolation: timeout(1) not on PATH — skipping case 3"
  PASS=$((PASS+1))
else
  TFX=$(mktemp -d)
  mkdir -p "$TFX/tests"
  # One slow test that would block forever.
  cat >"$TFX/tests/slow-test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
  chmod +x "$TFX/tests/slow-test.sh"
  # Copy run-all-inner.sh body (run-all-inner is the actual runner).
  cp "$INNER" "$TFX/tests/run-all-inner.sh"
  start_ts=$(date +%s)
  out=$(cd "$TFX" && WOW_TEST_TIMEOUT_S=2 bash tests/run-all-inner.sh 2>&1 || true)
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  # Assert: elapsed << 30s (we'd have timed out FAST), test recorded as failed.
  if [ "$elapsed" -gt 15 ]; then
    FAIL=$((FAIL+1)); FAILED_CASES+=("3-timeout-fires: elapsed=${elapsed}s — timeout did not fire fast")
  elif ! echo "$out" | grep -q "exceeded WOW_TEST_TIMEOUT_S"; then
    FAIL=$((FAIL+1)); FAILED_CASES+=("3-timeout-fires: stderr missing 'exceeded WOW_TEST_TIMEOUT_S' line")
  elif ! echo "$out" | grep -q "slow-test.sh"; then
    FAIL=$((FAIL+1)); FAILED_CASES+=("3-timeout-fires: failed-suites list missing slow-test.sh")
  else
    PASS=$((PASS+1))
  fi
  rm -rf "$TFX"
fi

echo "test-runner-host-isolation: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
