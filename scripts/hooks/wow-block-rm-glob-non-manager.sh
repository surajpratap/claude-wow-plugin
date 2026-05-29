#!/usr/bin/env bash
# Story 160 Layer E — PreToolUse hook that blocks `rm`+glob for non-M roles.
#
# Why: CC's bypass-permissions mode does NOT cover destructive glob patterns.
# A non-M role that runs `rm path/*` stalls indefinitely waiting for a
# permission prompt it cannot answer. This hook converts the silent stall
# into an immediate actionable rejection with remediation pointers.
#
# Stdin:  CC PreToolUse JSON envelope (`{tool_name, tool_input: {command, ...}, ...}`)
# Stdout: `{decision: "block", reason: "..."}` JSON on block, OR empty (= allow).
# Exit:   always 0 (allowing CC to surface the decision JSON).

set -u

INPUT=$(cat)

# Extract the command. If extraction fails, fall through to allow.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
if [ -z "$CMD" ]; then
  exit 0
fi

# Round-2 fix: broad regex biased to false positives. Match `rm` as a word
# boundary, then ANY of `*`/`?`/`[` later in the command. Escaped/quoted
# globs (`rm "*"`) also match — the role can request an M-nudge bypass.
# False negatives (silent fork-bomb) are much worse than false positives.
if ! printf '%s' "$CMD" | grep -qE '\brm\b' 2>/dev/null; then
  exit 0
fi
if ! printf '%s' "$CMD" | grep -qE '[*?[]' 2>/dev/null; then
  exit 0
fi

# Both `rm` and a glob char present. Resolve role.
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
