#!/usr/bin/env bash
# Story 144 — sourceable readiness helper for the webhook bridge test.
# Replaces a fixed `sleep` (the :55303-class startup race) with a poll for OUR
# bridge's own `armed` readiness signal on stdout. PP REQUIRED-3: identity comes
# from the bridge's emitted `bridge-status` (state=armed) in OUTFILE — NOT a
# forgeable port probe (run.py is do_POST-only; the port id is port-derived).
# Sourced from tests/*.sh; run-all globs top-level tests/*.sh, not tests/lib/.

# wait_for_bridge OUTFILE [TIMEOUT_SEC]
#   Poll OUTFILE until an `armed` bridge-status line appears (the bridge finished
#   startup, webhook or polling-fallback), up to TIMEOUT (default 10s).
#   Returns 0 once seen, 1 on timeout.
wait_for_bridge() {
  local outfile="$1" timeout="${2:-10}" i=0 steps
  steps=$(( timeout * 10 ))
  while [ "$i" -lt "$steps" ]; do
    if [ -f "$outfile" ] \
       && grep '"type":"bridge-status"' "$outfile" 2>/dev/null | grep -q 'armed'; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# wait_for_line OUTFILE PATTERN [TIMEOUT_SEC]
#   Poll OUTFILE until a line matches PATTERN (a terminal/sequence signal, e.g.
#   "exhausted retries"), up to TIMEOUT (default 20s). Replaces a fixed `sleep`
#   that's too short for a multi-step sequence under load. Returns 0 once seen.
wait_for_line() {
  local outfile="$1" pattern="$2" timeout="${3:-20}" i=0 steps
  steps=$(( timeout * 10 ))
  while [ "$i" -lt "$steps" ]; do
    if [ -f "$outfile" ] && grep -q "$pattern" "$outfile" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
