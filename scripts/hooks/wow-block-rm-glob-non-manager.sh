#!/usr/bin/env bash
# Story 160 Layer E — PreToolUse hook that blocks `rm`+glob for non-M roles.
# Story 173 — structure-aware: fires ONLY on a genuine rm-family remover in
# COMMAND POSITION carrying a glob, not on any command that merely contains the
# word `rm` and a glob char somewhere (which over-blocked `git add 'a/*'`,
# `grep 'rm.*x'`, `echo "rm *"`, ...).
#
# Why: CC's bypass-permissions mode does NOT cover destructive glob patterns.
# A non-M role that runs `rm path/*` stalls indefinitely waiting for a
# permission prompt it cannot answer. This hook converts the silent stall
# into an immediate actionable rejection with remediation pointers.
#
# Detection is delegated to the sibling `_rm-glob-detect.py` (quote-aware
# tokenization via stdlib shlex): exit 0 = a destructive remover-in-command-
# position + glob (block candidate); exit 1 = allow. `find -delete` /
# `find -exec rm` are intentionally allowed — they are the recommended escape
# hatch and not the shell-glob `rm` stall this guard targets.
#
# Stdin:  CC PreToolUse JSON envelope (`{tool_name, tool_input: {command, ...}}`)
# Stdout: `{decision: "block", reason: "..."}` JSON on block, OR empty (= allow).
# Exit:   always 0 (allowing CC to surface the decision JSON).

set -u

INPUT=$(cat)

# Extract the command. If extraction fails, fall through to allow.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
if [ -z "$CMD" ]; then
  exit 0
fi

# Structure-aware detection. Sibling detector resolved from this script's own
# location (works for the installed plugin and for in-tree tests); fall back to
# ${CLAUDE_PLUGIN_ROOT} only if the sibling is absent. exit 1 = allow.
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
DETECT="${HOOK_DIR}/_rm-glob-detect.py"
if [ ! -f "$DETECT" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  DETECT="${CLAUDE_PLUGIN_ROOT}/scripts/hooks/_rm-glob-detect.py"
fi
if ! printf '%s' "$CMD" | python3 "$DETECT"; then
  exit 0   # allow — no destructive remover-in-command-position + glob
fi

# A genuine destructive rm-glob is present. Resolve role.
WMR=$(wow-locate scripts/whats-my-role.sh 2>/dev/null || true)
ROLE=""
if [ -n "$WMR" ]; then
  ROLE=$(bash "$WMR" whats-my-role 2>/dev/null || true)
fi

# M is exempt — user-facing, the human approves any permission prompt directly.
if [ "$ROLE" = "manager" ]; then
  exit 0
fi

REASON='You are trying to `rm` with a shell glob. CC bypass-permissions mode does NOT cover destructive glob patterns. Your session will stall waiting for a permission prompt you cannot answer. Do this instead: (1) prepare a glob-free equivalent (`find <dir> -type f -name '"'"'<pattern>'"'"' -delete 2>/dev/null` OR `rm -f <dir>/specific-file 2>/dev/null`); (2) if the case is legitimate, ask M for a nudge bypass via a bus question/answer cycle. If the cleanup target is `.claude/`, use the existing `wow_sweep_stale_role_markers` helper.'

REASON_E="$REASON" python3 - <<'PY'
import json, os
print(json.dumps({
    "decision": "block",
    "reason": os.environ["REASON_E"],
}))
PY
exit 0
