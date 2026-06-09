#!/usr/bin/env bash
# Tests wow-tool-use-idle-reminder.sh — PostToolUse hook that surfaces a
# resume_work reminder (via hookSpecificOutput.additionalContext) when the
# .nothing_to_do idle marker is set and a work tool (Bash/Read/Write/Edit) is
# used. Reminder-only · global · throttled once per marker-episode per session
# (session_id key; episode = the marker's ts).
#
# Feasibility note: a PostToolUse hook's additionalContext on exit 0 IS
# delivered to the model (smoke-tested 2026-06-08, CC 2.1.168 — see the plan).
# This suite asserts the hook EMITS the correct additionalContext JSON (its
# controllable contract); CC's delivery is verified out-of-band by that smoke
# test (a nested-live-model check can't run in the offline suite).
#
# Cases:
#  c1 marker set + tool in-set             → emits additionalContext w/ resume_work
#  c2 marker absent                        → silent (empty stdout)
#  c3 marker set + tool OUT of set         → silent
#  c4 reminder-only                        → marker still present after hook
#  c5 throttle: 2nd call (same session+ts) → silent
#  c6 reset: new marker ts (same session)  → emits again

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_eq() { local n="$1" e="$2" a="$3"
  if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected '$e', got '$a')"); fi; }
assert_contains() { local n="$1" needle="$2" hay="$3"
  case "$hay" in *"$needle"*) PASS=$((PASS+1)) ;; *) FAIL=$((FAIL+1)); FAILED_CASES+=("$n (no '$needle' in '$hay')") ;; esac; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/scripts/hooks/wow-tool-use-idle-reminder.sh"

mk_project() { local d; d=$(mktemp -d); mkdir -p "$d/implementations"; echo "$d"; }
set_marker() { printf '%s\n' "{\"ts\":\"$2\",\"declared_by\":\"manager\",\"reason\":null}" > "$1/implementations/.nothing_to_do"; }
present() { [ -f "$1/implementations/.nothing_to_do" ] && echo yes || echo no; }
run_hook() { local p="$1" tool="$2" sid="$3"
  printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"$tool\",\"session_id\":\"$sid\",\"tool_response\":{}}" \
    | CLAUDE_PROJECT_DIR="$p" bash "$HOOK"; }
ac() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# c1: marker set + Bash → emits additionalContext containing resume_work
P=$(mk_project); set_marker "$P" "2026-06-08T10:00:00Z"
OUT=$(run_hook "$P" Bash sess-A)
assert_contains "c1-present-emits" "resume_work" "$(ac "$OUT")"
rm -rf "$P"

# c2: no marker → silent
P=$(mk_project)
OUT=$(run_hook "$P" Bash sess-A)
assert_eq "c2-absent-silent" "" "$OUT"
rm -rf "$P"

# c3: marker set + out-of-set tool (Glob) → silent
P=$(mk_project); set_marker "$P" "2026-06-08T10:00:00Z"
OUT=$(run_hook "$P" Glob sess-A)
assert_eq "c3-out-of-set-silent" "" "$OUT"
rm -rf "$P"

# c4: reminder-only — marker still present after the hook runs
P=$(mk_project); set_marker "$P" "2026-06-08T10:00:00Z"
run_hook "$P" Read sess-A >/dev/null
assert_eq "c4-reminder-only-marker-present" "yes" "$(present "$P")"
rm -rf "$P"

# c5 (throttle): 2nd call (same session + same episode ts) → silent
# RED-WITHOUT: patch .red-without/182-tool-use-reminder-throttle.patch -> c5-throttle-second-silent
P=$(mk_project); set_marker "$P" "2026-06-08T10:00:00Z"
OUT1=$(run_hook "$P" Bash sess-T)
OUT2=$(run_hook "$P" Bash sess-T)
assert_contains "c5-first-emits" "resume_work" "$(ac "$OUT1")"
assert_eq "c5-throttle-second-silent" "" "$OUT2"
rm -rf "$P"

# c6 (reset): new marker ts = new episode → emits again (same session)
P=$(mk_project); set_marker "$P" "2026-06-08T10:00:00Z"
run_hook "$P" Bash sess-R >/dev/null              # first episode → reminded
set_marker "$P" "2026-06-08T11:30:00Z"            # clear+re-set: new ts
OUT=$(run_hook "$P" Bash sess-R)
assert_contains "c6-reset-after-reepisode" "resume_work" "$(ac "$OUT")"
rm -rf "$P"

echo; echo "tool-use-idle-reminder: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
