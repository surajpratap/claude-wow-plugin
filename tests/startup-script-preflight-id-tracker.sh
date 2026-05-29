#!/usr/bin/env bash
# Story 152 — M's phase_peer writes a TRANSIENT preflight tracker
# BEFORE emitting pings, and removes it after pong-collection (via
# trap EXIT). The tracker existing during the ping window satisfies
# story 149's dead-agent-ID guard so peers can pong by exact ID.
#
# This test runs M's startup.sh and asserts (1) a manager-preflight-*
# tracker file existed at some point during phase_peer, (2) it was
# removed by the time startup.sh completes.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations"
echo "falcon" > "$PROJ/implementations/.my-team"

# Capture stdout for the "preflight tracker written" emit
OUT=$(WOW_ROOT="$PROJ" bash "$STARTUP" --role manager 2>/dev/null)

# Case 1: stdout shows a preflight tracker was written
if printf '%s' "$OUT" | grep -q "preflight tracker written at .*manager-preflight-"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case1: phase_peer did not log writing a preflight tracker")
fi

# Case 2: by the time startup completes, NO manager-preflight-*.json
# file remains (the trap EXIT cleaned it up)
preflight_files=$(ls "$PROJ/implementations/.agents/"manager-preflight-*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$preflight_files" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case2: $preflight_files preflight tracker(s) survived startup (trap EXIT failed)")
fi

# Case 3: SD/PP/T do NOT write a preflight tracker (M-only)
for role in senior-developer pair-programmer tester; do
  rm -rf "$PROJ/implementations/.agents" 2>/dev/null
  OUT=$(WOW_ROOT="$PROJ" bash "$STARTUP" --role "$role" 2>/dev/null)
  if printf '%s' "$OUT" | grep -q "preflight tracker"; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3: $role wrote a preflight tracker (should be M-only)")
  else
    PASS=$((PASS+1))
  fi
done

rm -rf "$PROJ"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
