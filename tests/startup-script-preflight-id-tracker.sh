#!/usr/bin/env bash
# Story 152 + 161 (FINDING-41 fix) — M's phase_peer writes a preflight
# tracker BEFORE emitting pings and lets it persist past startup.sh
# exit. The tracker satisfies the dead-agent-ID guard so peers can
# pong by exact ID. M's operating doctrine (commands/manager.md
# "Post-startup preflight cleanup") removes it after pong-collection.
#
# This test runs M's startup.sh and asserts (1) a manager-preflight-*
# tracker file was written, (2) it PERSISTS past startup.sh exit
# (FINDING-41 fix — the prior trap EXIT defeated the dead-agent-ID
# guard), (3) SD/PP/T do not write a preflight tracker.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations"
echo "falcon" > "$PROJ/implementations/.my-team"

# Capture stdout for the "preflight tracker written" emit
OUT=$(WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --role manager 2>/dev/null)

# Case 1: stdout shows a preflight tracker was written
if printf '%s' "$OUT" | grep -q "preflight tracker written at .*manager-preflight-"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case1: phase_peer did not log writing a preflight tracker")
fi

# Case 2: exactly one manager-preflight-*.json file PERSISTS past
# startup.sh exit. The trap EXIT removal pre-fix defeated the
# dead-agent-ID guard; the fix removes the trap so M's operating
# doctrine cleans up after pong-collection instead.
preflight_files=$(ls "$PROJ/implementations/.agents/"manager-preflight-*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$preflight_files" -eq 1 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case2: expected 1 preflight tracker post-startup, got $preflight_files (FINDING-41 regression — trap reintroduced or write failed)")
fi

# Case 3: SD/PP/T do NOT write a preflight tracker (M-only)
for role in senior-developer pair-programmer tester; do
  rm -rf "$PROJ/implementations/.agents" 2>/dev/null
  OUT=$(WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --role "$role" 2>/dev/null)
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
