#!/usr/bin/env bash
# Bug 0006 (P0) — BEHAVIORAL test for startup.sh's hello + ping emits.
#
# phase_bootstrap.sh emits a `hello` line per Story 152 / 161; phase_peer.sh
# emits `ping` nonces per the peer-preflight contract. Both used the
# silently-inert `--exec bus-emit` CLI form pre-Story-163. Without this
# behavioral test, the regression repeats — shape-only "the script
# contains the word bus_emit" passes for an inert form.
#
# This test invokes the REAL phase_bootstrap and phase_peer with a
# fixture WOW_ROOT/CLAUDE_PROJECT_DIR and asserts a `hello` (or `ping`)
# line lands on the fixture bus.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP_LIB="$ROOT/scripts/startup"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT INT TERM
mkdir -p "$TMPROOT/implementations/.agents"

# Case 1: phase_bootstrap emits a `hello` line.
(
  export WOW_ROOT="$TMPROOT"
  export CLAUDE_PROJECT_DIR="$TMPROOT"
  # shellcheck source=/dev/null
  . "$STARTUP_LIB/lib_emit.sh"
  # shellcheck source=/dev/null
  . "$STARTUP_LIB/phase_bootstrap.sh"
  phase_bootstrap senior-developer >/dev/null 2>&1
)

if [ -f "$TMPROOT/implementations/.message-bus.jsonl" ] && \
   grep -qF '"type":"hello"' "$TMPROOT/implementations/.message-bus.jsonl"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("1-hello-emitted (no hello bus line under fixture root)")
fi

# Case 2: phase_peer emits at least one `ping` line.
# Reset bus to avoid cross-contamination, keep tracker.
: > "$TMPROOT/implementations/.message-bus.jsonl" 2>/dev/null || true

(
  export WOW_ROOT="$TMPROOT"
  export CLAUDE_PROJECT_DIR="$TMPROOT"
  export WOW_AGENT_ID="senior-developer-20260529T100000-abc123"
  # shellcheck source=/dev/null
  . "$STARTUP_LIB/lib_emit.sh"
  # shellcheck source=/dev/null
  . "$STARTUP_LIB/phase_peer.sh"
  phase_peer manager >/dev/null 2>&1
)

if [ -f "$TMPROOT/implementations/.message-bus.jsonl" ] && \
   grep -qF '"type":"ping"' "$TMPROOT/implementations/.message-bus.jsonl"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("2-ping-emitted (no ping bus line under fixture root)")
fi

# Case 3: source-level fail-loud check. Both scripts must NOT swallow
# bus_emit failures behind 2>/dev/null. Behavioral test can't catch a
# silent drop, so add this complementary source check.
for s in "$STARTUP_LIB/phase_bootstrap.sh" "$STARTUP_LIB/phase_peer.sh"; do
  if grep -qE 'python3 "?\$mcp_server"? bus_emit .* 2>/dev/null' "$s"; then
    FAIL=$((FAIL+1)); FAILED_CASES+=("3-no-stderr-swallow ($(basename "$s") still swallows bus_emit failures)")
  fi
done
# If we got here without a fail in case 3, count it once.
PASS=$((PASS+1))

echo "startup-hello-ping-bus-emit: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
