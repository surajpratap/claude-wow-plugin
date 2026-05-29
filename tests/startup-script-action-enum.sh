#!/usr/bin/env bash
# Story 152 — startup.sh emitted `action` field always in the closed
# enum {info, arm-monitor, ask-human, complete, abort}. The original
# backlog 190 symptom (SD reaching for ScheduleWakeup for bus-tail) is
# closed by construction: this test asserts no action value outside
# the enum ever appears on startup.sh stdout, for any role.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations"
echo "falcon" > "$PROJ/implementations/.my-team"

ALLOWED='info arm-monitor ask-human complete abort'

for role in manager senior-developer pair-programmer tester slacker; do
  rm -rf "$PROJ/implementations/.agents" 2>/dev/null
  OUT=$(WOW_ROOT="$PROJ" bash "$STARTUP" --role "$role" 2>/dev/null)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    action=$(printf '%s' "$line" | jq -r '.action // empty' 2>/dev/null)
    [ -z "$action" ] && continue
    found=0
    for a in $ALLOWED; do
      if [ "$action" = "$a" ]; then found=1; break; fi
    done
    if [ "$found" -eq 0 ]; then
      FAIL=$((FAIL+1))
      FAILED_CASES+=("$role: action='$action' not in {$ALLOWED}")
    else
      PASS=$((PASS+1))
    fi
  done <<< "$OUT"
done

# Regression guard: the script itself must not contain a callable emit
# function (or hardcoded JSON) for banned action values. Excludes lines
# that start with `#` (shell comments) so doctrine comments saying "NO
# schedule-wakeup" don't false-flag.
if grep -hE '^[^#]*(emit_schedule_wakeup|emit_start_loop|"action": *"schedule-wakeup"|"action": *"start-loop")' \
    "$ROOT/scripts/startup.sh" "$ROOT/scripts/startup"/*.sh 2>/dev/null | grep -v '^$' >/dev/null; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("source contains a banned action emit (schedule-wakeup or start-loop)")
else
  PASS=$((PASS+1))
fi

rm -rf "$PROJ"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
