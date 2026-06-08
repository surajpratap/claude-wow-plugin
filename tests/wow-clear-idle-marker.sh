#!/usr/bin/env bash
# Tests wow-clear-idle-marker.sh — UserPromptSubmit hook that mechanically
# clears the .nothing_to_do idle marker. Idempotent · role-agnostic ·
# NEVER touches AFK state.
#
# Cases:
# 1. marker present + prompt        → marker removed, exit 0   (AC1, AC6)
# 2. marker absent  + prompt        → no-op, exit 0            (AC1 idempotent)
# 3. marker present + AFK state set → marker removed AND tracker/.afk bytes unchanged (AC2, AC6)
# 4. marker present + non-M / no role marker → STILL removed   (AC1 "every prompt"; role-gate dropped)
# 5. hook emits nothing on stdout (no additionalContext)       (pins the path-1 emission decision; PP BLOCKER)

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_eq() { local n="$1" e="$2" a="$3"
  if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (expected '$e', got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/scripts/hooks/wow-clear-idle-marker.sh"
STDIN_JSON='{"hook_event_name":"UserPromptSubmit","prompt":"hello"}'

mk_project() { local d; d=$(mktemp -d); mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations/.afk"; echo "$d"; }
set_marker() { echo '{"ts":"2026-06-08T10:00:00Z","declared_by":"manager","reason":null}' > "$1/implementations/.nothing_to_do"; }
present() { [ -f "$1/implementations/.nothing_to_do" ] && echo yes || echo no; }

# Case 1: marker present + prompt → removed, exit 0
# RED-WITHOUT: patch .red-without/179-clear-idle-marker.patch -> case-1-marker-removed
P=$(mk_project); set_marker "$P"
echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK"; RC=$?
assert_eq "case-1-marker-removed" "no" "$(present "$P")"
assert_eq "case-1-exit-0" "0" "$RC"
rm -rf "$P"

# Case 2: marker absent + prompt → no-op, exit 0
P=$(mk_project)
echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK"; RC=$?
assert_eq "case-2-still-absent" "no" "$(present "$P")"
assert_eq "case-2-exit-0" "0" "$RC"
rm -rf "$P"

# Case 3: AFK state present → marker removed AND AFK bytes unchanged (AC2/AC6)
P=$(mk_project); set_marker "$P"
TRACKER="$P/implementations/.m-offset-tracker.json"
printf '%s\n' '{"afk_active":true,"afk_mode":"leader","afk_started_ts":"2026-06-08T05:48:00Z"}' > "$TRACKER"
MIRROR="$P/implementations/.afk/sess-1-decisions.md"; printf '%s\n' '# afk session' > "$MIRROR"
SHA_BEFORE=$(cat "$TRACKER" "$MIRROR" | shasum | awk '{print $1}')
echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK"
SHA_AFTER=$(cat "$TRACKER" "$MIRROR" | shasum | awk '{print $1}')
assert_eq "case-3-marker-removed" "no" "$(present "$P")"
assert_eq "case-3-afk-bytes-unchanged" "$SHA_BEFORE" "$SHA_AFTER"
rm -rf "$P"

# Case 4: non-M role (and no-role) still clears — role-gate dropped (AC1)
P=$(mk_project); set_marker "$P"; echo "senior-developer" > "$P/.claude/.session-role-by-claude-pid/$$"
echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK"
assert_eq "case-4-removed-non-m" "no" "$(present "$P")"
rm -rf "$P"

# Case 5: hook emits NOTHING on stdout (deliberately-absent emission; pins path 1 / PP BLOCKER)
P=$(mk_project); set_marker "$P"
OUT=$(echo "$STDIN_JSON" | CLAUDE_PROJECT_DIR="$P" bash "$HOOK")
assert_eq "case-5-no-stdout-emission" "" "$OUT"
rm -rf "$P"

echo; echo "wow-clear-idle-marker: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
