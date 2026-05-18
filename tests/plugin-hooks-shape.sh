#!/usr/bin/env bash
# Story 060 — plugin hooks live at canonical path with canonical env var.
#
# Asserts the plugin ships hooks via `hooks/hooks.json` at plugin root,
# PreToolUse + Stop are declared (6-hook router: PreToolUse, UserPromptSubmit,
# Stop, StopFailure, SessionStart, SessionEnd), all command paths use
# ${CLAUDE_PLUGIN_ROOT} (NOT $CLAUDE_PROJECT_DIR or $CLAUDE_PLUGIN_DIR),
# and the project's .claude/settings.json no longer contains a `hooks`
# block (would silently re-enable the wrong-layer pattern + double-fire
# per the additive merge rule).
#
# Cases:
# 1. Plugin hooks file at canonical path (NOT under .claude-plugin/)
# 2. Both PreToolUse + Stop declared with at least one entry each
# 3. All hook command paths use ${CLAUDE_PLUGIN_ROOT}; none use
#    $CLAUDE_PROJECT_DIR or $CLAUDE_PLUGIN_DIR
# 4. Project .claude/settings.json does NOT contain a `hooks` block
# 5. Hook script ${CLAUDE_PLUGIN_ROOT} fallback derives from $0 when env
#    var is unset (defensive guard added in this story)

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

assert_true() {
  local name="$1"; local rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected rc=0, got rc=$rc)")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$(cd "$ROOT/.." && pwd)"
PLUGIN_HOOKS="$ROOT/hooks/hooks.json"
WRONG_PATH="$ROOT/.claude-plugin/hooks/hooks.json"
# .claude/settings.json lives at the source repo root, not in plugin/.
PROJECT_SETTINGS="$SOURCE_ROOT/.claude/settings.json"
ASKUSER_HOOK="$ROOT/scripts/hooks/check-askuserquestion-role.sh"

# -----------------------------------------------------------------------------
# Case 1: Plugin hooks file at canonical path (NOT under .claude-plugin/)
# -----------------------------------------------------------------------------
if [ -f "$PLUGIN_HOOKS" ]; then RC_CANONICAL=0; else RC_CANONICAL=1; fi
assert_true "case-1-canonical-path-exists" "$RC_CANONICAL"
if [ ! -f "$WRONG_PATH" ]; then RC_WRONG=0; else RC_WRONG=1; fi
assert_true "case-1-wrong-path-absent" "$RC_WRONG"

# -----------------------------------------------------------------------------
# Case 2: Both PreToolUse + Stop declared with >=1 entry each
# (6-hook router replaced PostToolUse with PreToolUse + 5 lifecycle events)
# -----------------------------------------------------------------------------
PRE_LEN=$(jq '.hooks.PreToolUse | length' "$PLUGIN_HOOKS" 2>/dev/null)
STOP_LEN=$(jq '.hooks.Stop | length' "$PLUGIN_HOOKS" 2>/dev/null)
[ "${PRE_LEN:-0}" -ge 1 ] && PRE_OK=ok || PRE_OK=missing
[ "${STOP_LEN:-0}" -ge 1 ] && STOP_OK=ok || STOP_OK=missing
assert_eq "case-2-pretooluse-declared" "ok" "$PRE_OK"
assert_eq "case-2-stop-declared" "ok" "$STOP_OK"

# -----------------------------------------------------------------------------
# Case 3: All command paths use ${CLAUDE_PLUGIN_ROOT}; none use legacy vars
# -----------------------------------------------------------------------------
COMMANDS=$(jq -r '.. | objects | select(has("command")) | .command' "$PLUGIN_HOOKS" 2>/dev/null)
COUNT_TOTAL=$(echo "$COMMANDS" | grep -c .)
COUNT_PLUGIN_ROOT=$(echo "$COMMANDS" | grep -c 'CLAUDE_PLUGIN_ROOT')
COUNT_PROJECT_DIR=$(echo "$COMMANDS" | grep -c 'CLAUDE_PROJECT_DIR' || true)
COUNT_PLUGIN_DIR=$(echo "$COMMANDS" | grep -c 'CLAUDE_PLUGIN_DIR' || true)
assert_eq "case-3-all-commands-use-plugin-root" "$COUNT_TOTAL" "$COUNT_PLUGIN_ROOT"
assert_eq "case-3-no-project-dir-references" "0" "$COUNT_PROJECT_DIR"
assert_eq "case-3-no-plugin-dir-references" "0" "$COUNT_PLUGIN_DIR"

# -----------------------------------------------------------------------------
# Case 4: Project .claude/settings.json does NOT contain `hooks` block
# (Would silently re-enable wrong-layer + double-fire per additive merge.)
# -----------------------------------------------------------------------------
jq -e 'has("hooks") | not' "$PROJECT_SETTINGS" >/dev/null 2>&1
assert_true "case-4-project-settings-no-hooks" "$?"

# -----------------------------------------------------------------------------
# Case 5: Hook script ${CLAUDE_PLUGIN_ROOT} fallback derives from $0 when
# the env var is unset. Guard line is at the top of both hook scripts;
# this case verifies the script doesn't crash when CLAUDE_PLUGIN_ROOT is
# unset and that PLUGIN_DIR ends up correctly set.
#
# We can't easily inspect PLUGIN_DIR from outside the script (it's a local
# var). Instead: spawn the script with marker present (manager) so it
# exits 0 cleanly, and verify the script ran without erroring on the
# fallback expression. If the fallback `cd "$(dirname "$0")/.."` failed,
# the script would crash (set -u on undefined var, or cd error).
# -----------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude/.session-role-by-claude-pid"
echo "manager" > "$TMPDIR/.claude/.session-role-by-claude-pid/$$"
# Story 053 subshell-PPID trap: do NOT wrap `bash $HOOK` in `(...)` — the
# subshell interposes and the hook's $PPID lands on the subshell, not on
# this test process; the marker lookup fails and the hook exits 2.
# Direct invocation keeps $PPID == this script's PID.
unset CLAUDE_PLUGIN_ROOT
CLAUDE_PROJECT_DIR="$TMPDIR" bash "$ASKUSER_HOOK" </dev/null >/dev/null 2>&1
RC5=$?
assert_eq "case-5-fallback-no-crash-with-unset-env" "0" "$RC5"
rm -rf "$TMPDIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "plugin-hooks-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
