#!/usr/bin/env bash
# post-compact-rearm-verify.sh — confirm each tracker-armed Monitor is alive
# after the PostCompact restore handler ran (Story 105). Lists STILL-MISSING
# purposes on stderr; agents must NEVER substitute a poll-based Bash watcher.
#
# Exit codes: 0 all expected Monitors alive,
#             1 one or more STILL-MISSING,
#             2 role-process-map.json not found,
#             3 role marker missing.

set -u

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Story 133 (FINDING-35): resolve role via whats-my-role.sh, NOT a fixed-path
# .claude-plugin/current-role file (no script writes that path). The real
# marker is per-claude-PID under .claude/.session-role-by-claude-pid/<pid>.
# $WOW_ROLE_OVERRIDE is a test-only knob: when set, skip the helper walk
# (whose PPID-walk needs a claude ancestor, unavailable from test subshells).
ROLE="${WOW_ROLE_OVERRIDE:-}"
if [ -z "$ROLE" ]; then
  WMR="$(wow-locate scripts/whats-my-role.sh 2>/dev/null || echo "$SCRIPT_DIR/../whats-my-role.sh")"
  ROLE=$(bash "$WMR" whats-my-role 2>/dev/null || true)
fi
[ -n "$ROLE" ] || { echo "[rearm-verify] role marker not found (no .claude/.session-role-by-claude-pid/<pid> for this session)" >&2; exit 3; }

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MAP=$(
  ls "${WOW_ROOT}/.claude/scripts/wow-process/role-process-map.json" 2>/dev/null \
  || ls "${WOW_ROOT}/scripts/wow-process/role-process-map.json" 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/role-process-map.json 2>/dev/null | head -1
)
[ -n "$MAP" ] && [ -f "$MAP" ] || { echo "[rearm-verify] role-process-map.json not found" >&2; exit 2; }

PURPOSES=$(bash "$SCRIPT_DIR/tracker-armed-purposes.sh" 2>/dev/null || true)
if [ -z "$PURPOSES" ]; then
  PURPOSES=$(jq -r --arg r "$ROLE" '.[$r] // [] | .[]' "$MAP" 2>/dev/null || true)
fi

WOW_PROCESS_DIR="${WOW_ROOT}/implementations/.wow-process"
MISSING=0
for p in $PURPOSES; do
  if ! jq -e --arg r "$ROLE" --arg p "$p" '.[$r] // [] | any(. == $p)' "$MAP" >/dev/null 2>&1; then
    continue
  fi
  PIDFILE="${WOW_PROCESS_DIR}/${p}-${ROLE}.pid"
  if [ -f "$PIDFILE" ]; then
    PID=$(tr -d '[:space:]' < "$PIDFILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      continue
    fi
  fi
  WRAP="${SCRIPT_DIR}/${p}.sh"
  printf 'STILL-MISSING\t%s\t%s\n' "$p" "$WRAP" >&2
  MISSING=$((MISSING + 1))
done

[ "$MISSING" -eq 0 ] && exit 0 || exit 1
