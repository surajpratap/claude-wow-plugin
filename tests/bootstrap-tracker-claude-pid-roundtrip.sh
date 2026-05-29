#!/usr/bin/env bash
# Bug 0010 — phase_bootstrap must record the CLAUDE-ancestor PID
# (wow_find_claude_pid), NOT ${PPID}. ${PPID} is the transient bash that ran
# phase_bootstrap inside startup.sh's pipeline; it has already exited by the
# next boot, so the writer (phase_bootstrap) and the reader
# (wow-existing-agent-id.sh -> wow_find_claude_pid, which walks to `claude`)
# computed different pids and the tracker never resolved — re-opening Story
# 121's idempotency contract on every startup.sh boot.
#
# This is a BEHAVIORAL producer->consumer round-trip, NOT a source grep
# (per the dx-batch retro headline: a fixture that re-encodes the SUT proves
# nothing about the real contract):
#   producer = the REAL phase_bootstrap tracker-init (writes claude_pid)
#   consumer = the REAL wow-existing-agent-id.sh (resolves the tracker)
#
# Determinism problem: wow_find_claude_pid walks the REAL process tree to a
# `claude` ancestor, so this very test — if launched from inside a real claude
# session — would find THAT claude. We therefore drive the real phase_bootstrap
# under a PATH-shimmed `ps` that GRAFTS a synthetic node->claude chain onto the
# test-body pid (WOW_TEST_CUTPOINT) and DELEGATES to the real ps for every other
# pid. Descendants of the test body walk the real tree up to the cutpoint, then
# into the graft; the graft cuts the real ancestry above the cutpoint, so both
# the positive (claude found) and negative (no claude -> 0 fallback) cases are
# deterministic regardless of how the suite was launched. ONLY `ps` is stubbed;
# phase_bootstrap.sh's tracker-init, wow_find_claude_pid, and
# wow-existing-agent-id.sh all run for real.

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

ROOT_PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
PB="$ROOT_PLUGIN/scripts/startup/phase_bootstrap.sh"
LIB_EMIT="$ROOT_PLUGIN/scripts/startup/lib_emit.sh"
WMR="$ROOT_PLUGIN/scripts/whats-my-role.sh"
READER="$ROOT_PLUGIN/scripts/wow-existing-agent-id.sh"
for f in "$PB" "$LIB_EMIT" "$WMR" "$READER"; do
  [ -f "$f" ] || { echo "bootstrap-tracker-claude-pid-roundtrip: FATAL missing $f"; exit 2; }
done

REAL_PS="$(command -v ps || echo /bin/ps)"
FAKE_NODE_PID=999001
FAKE_CLAUDE_PID=999002

# ---- graft ps-shim (everything from env; quoted heredoc -> no escaping) ----
make_shim() {
  cat > "$1/ps" <<'SHIM'
#!/usr/bin/env bash
REAL_PS="${WOW_TEST_REAL_PS:-/bin/ps}"
opt=""; pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) opt="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid" in
  "${WOW_TEST_CLAUDE_PID:-__none__}")
    [ "$opt" = "command=" ] && echo "claude --resume"
    [ "$opt" = "ppid=" ] && echo "1"
    ;;
  "${WOW_TEST_NODE_PID:-__none__}")
    [ "$opt" = "command=" ] && echo "node /opt/claude/cli.js"
    [ "$opt" = "ppid=" ] && echo "${WOW_TEST_CLAUDE_PID}"
    ;;
  "${WOW_TEST_CUTPOINT:-__none__}")
    if [ "$opt" = "ppid=" ]; then
      if [ "${WOW_TEST_MODE:-positive}" = "positive" ]; then
        echo "${WOW_TEST_NODE_PID}"
      else
        echo "1"
      fi
    else
      "$REAL_PS" -o "$opt" -p "$pid"
    fi
    ;;
  *)
    "$REAL_PS" -o "$opt" -p "$pid"
    ;;
esac
SHIM
  chmod +x "$1/ps"
}

# ---- driver: run the REAL phase_bootstrap, then the REAL reader ----
# Quoted heredoc: all vars resolve at driver runtime from the env we pass.
make_driver() {
  cat > "$1/driver.sh" <<'DRV'
#!/usr/bin/env bash
export WOW_TEST_CUTPOINT=$$
cd "$WOW_ROOT" || exit 3
# Pre-source so wow_find_claude_pid is defined even if wow-locate is absent;
# phase_bootstrap re-sources the same function at step 2 (identical body).
. "$WMR" 2>/dev/null || true
. "$LIB_EMIT" 2>/dev/null || true
. "$PB" 2>/dev/null || true
# Tracker-init (the SUT) runs in step 3, before the MCP/monitor steps, so the
# tracker is on disk regardless of how the later best-effort steps fare.
phase_bootstrap senior-developer >/dev/null 2>&1 || true
TRK=$(ls "$WOW_ROOT"/implementations/.agents/senior-developer-*.json 2>/dev/null | head -1)
CPID=$(jq -r '.claude_pid' "$TRK" 2>/dev/null)
RESOLVED=$(bash "$READER" senior-developer 2>/dev/null)
AGENTID=$(basename "${TRK:-none}" .json 2>/dev/null)
echo "CLAUDE_PID=${CPID:-MISSING}"
echo "RESOLVED=${RESOLVED:-}"
echo "AGENTID=${AGENTID:-none}"
DRV
  chmod +x "$1/driver.sh"
}

run_case() {
  local mode="$1"
  local outdir shimdir out
  outdir=$(mktemp -d)
  shimdir=$(mktemp -d)
  make_shim "$shimdir"
  make_driver "$outdir"
  out=$(WOW_ROOT="$outdir" CLAUDE_PROJECT_DIR="$outdir" \
        WMR="$WMR" LIB_EMIT="$LIB_EMIT" PB="$PB" READER="$READER" \
        WOW_TEST_REAL_PS="$REAL_PS" \
        WOW_TEST_NODE_PID="$FAKE_NODE_PID" WOW_TEST_CLAUDE_PID="$FAKE_CLAUDE_PID" \
        WOW_TEST_MODE="$mode" \
        PATH="$shimdir:$PATH" \
        bash "$outdir/driver.sh" 2>/dev/null)
  rm -rf "$outdir" "$shimdir"
  printf '%s\n' "$out"
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# ---- Case 1: positive round-trip — writer records the claude-ancestor pid ----
OUT=$(run_case positive)
CPID=$(field "$OUT" CLAUDE_PID)
RESOLVED=$(field "$OUT" RESOLVED)
AGENTID=$(field "$OUT" AGENTID)
case "$AGENTID" in senior-developer-*) WROTE=yes ;; *) WROTE=no ;; esac
assert_eq "positive-tracker-written" "yes" "$WROTE"
assert_eq "positive-writer-records-claude-ancestor-pid" "$FAKE_CLAUDE_PID" "$CPID"
# The producer->consumer round-trip: the reader resolves the just-written tracker.
assert_eq "positive-reader-resolves-tracker" "$AGENTID" "$RESOLVED"

# ---- Case 2: negative — no claude ancestor -> graceful 0 fallback ----
OUT=$(run_case negative)
CPID=$(field "$OUT" CLAUDE_PID)
assert_eq "negative-no-claude-ancestor-records-zero" "0" "$CPID"

# -----------------------------------------------------------------------------
echo "bootstrap-tracker-claude-pid-roundtrip: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
