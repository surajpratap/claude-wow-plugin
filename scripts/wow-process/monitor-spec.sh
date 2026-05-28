#!/usr/bin/env bash
# monitor-spec.sh — emit JSON spec for re-arming a wrapped-process Monitor
#. Given a <purpose>, prints a JSON object the agent feeds into
# the Monitor tool:
#   {
#     "command":       "bash <abs-path-to-wow-process/<purpose>.sh> [args]",
#     "env":           {"WOW_AGENT_ID":"...", "WOW_ROLE":"...", ...},
#     "description":   "<role> <purpose> — peer messages for <agent-id>",
#     "purpose":       "<purpose>",
#     "tracker_field": "<purpose-with-underscores>_task_id"
#   }
#
# Exit codes: 0 success, 1 purpose not in role's role-process-map,
#             2 role-process-map.json not found,
#             3 role marker missing.

set -u

PURPOSE="${1:-}"
if [ -z "$PURPOSE" ]; then
  echo "usage: monitor-spec.sh <purpose>" >&2
  exit 1
fi

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Story 133: resolve role via whats-my-role.sh, NOT the dead
# fixed-path .claude-plugin/current-role file. Marker lives per-claude-PID
# under .claude/.session-role-by-claude-pid/<pid>. $WOW_ROLE_OVERRIDE is a
# test-only knob.
ROLE="${WOW_ROLE_OVERRIDE:-}"
if [ -z "$ROLE" ]; then
  WMR="$(wow-locate scripts/whats-my-role.sh 2>/dev/null || echo "$SCRIPT_DIR/../whats-my-role.sh")"
  ROLE=$(bash "$WMR" whats-my-role 2>/dev/null || true)
fi
[ -n "$ROLE" ] || { echo "[monitor-spec] role marker not found (no .claude/.session-role-by-claude-pid/<pid> for this session)" >&2; exit 3; }

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MAP=$(
  ls "${WOW_ROOT}/.claude/scripts/wow-process/role-process-map.json" 2>/dev/null \
  || ls "${WOW_ROOT}/scripts/wow-process/role-process-map.json" 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/role-process-map.json 2>/dev/null | head -1
)
[ -n "$MAP" ] && [ -f "$MAP" ] || { echo "[monitor-spec] role-process-map.json not found" >&2; exit 2; }

if ! jq -e --arg r "$ROLE" --arg p "$PURPOSE" '.[$r] // [] | any((. | rtrimstr("?")) == $p)' "$MAP" >/dev/null 2>&1; then
  echo "[monitor-spec] purpose '$PURPOSE' not in role-process-map for '$ROLE'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAP_SCRIPT="${SCRIPT_DIR}/${PURPOSE}.sh"
[ -f "$WRAP_SCRIPT" ] || { echo "[monitor-spec] wrapped script not found: $WRAP_SCRIPT" >&2; exit 1; }

AGENT_ID="${WOW_AGENT_ID:-}"
if [ -z "$AGENT_ID" ]; then
  AGENT_ID=$(ls -t "${WOW_ROOT}/implementations/.agents/${ROLE}-"*.json 2>/dev/null \
    | head -1 | sed 's|.*/||; s|\.json$||')
fi
BUS_PATH="${WOW_ROOT}/implementations/.message-bus.jsonl"
TRACKER_FIELD="$(echo "$PURPOSE" | tr '-' '_')_task_id"

case "$PURPOSE" in
  bus-tail)
    CMD="bash $WRAP_SCRIPT $BUS_PATH $AGENT_ID $ROLE"
    # Story 125: propagate CLAUDE_PID into ENV_JSON so bus-tail.sh's
    # SIGINT activity-log emit (story 099) carries the real claude_pid per
    # story 098's `{ts, claude_pid, role, type, ...}` schema.
    ENV_JSON=$(jq -nc --arg a "$AGENT_ID" --arg r "$ROLE" --arg b "$BUS_PATH" --arg w "$WOW_ROOT" \
      --arg cp "${CLAUDE_PID:-0}" \
      '{WOW_AGENT_ID:$a, WOW_ROLE:$r, WOW_BUS:$b, WOW_ROOT:$w, CLAUDE_PID:$cp}')
    DESC="${ROLE} bus-tail — peer messages for ${AGENT_ID}"
    ;;
  github-bridge)
    BRIDGE_CONF="${WOW_ROOT}/implementations/.wow-process/github-bridge.conf"
    CMD="bash $WRAP_SCRIPT --config $BRIDGE_CONF"
    # Story 125 parity — same env-key shape as bus-tail.
    ENV_JSON=$(jq -nc --arg a "$AGENT_ID" --arg r "$ROLE" --arg b "$BUS_PATH" --arg w "$WOW_ROOT" \
      --arg cp "${CLAUDE_PID:-0}" \
      '{WOW_AGENT_ID:$a, WOW_ROLE:$r, WOW_BUS:$b, WOW_ROOT:$w, CLAUDE_PID:$cp}')
    DESC="${ROLE} github-bridge — PR events for ${AGENT_ID}"
    ;;
  idle-monitor)
    CMD="bash $WRAP_SCRIPT"
    ENV_JSON=$(jq -nc --arg p "$WOW_ROOT" --arg r "$ROLE" --arg w "$WOW_ROOT" \
      '{CLAUDE_PROJECT_DIR:$p, WOW_ROLE:$r, WOW_ROOT:$w}')
    DESC="${ROLE} idle-monitor — idle ticks"
    ;;
  *)
    # Generic fallback for future purposes; the agent's role doctrine + the
    # script's own README cover any non-standard env. Document this in the
    # purpose's <purpose>.sh header so this fallback stays trivial.
    CMD="bash $WRAP_SCRIPT"
    ENV_JSON=$(jq -nc --arg a "$AGENT_ID" --arg r "$ROLE" --arg w "$WOW_ROOT" \
      '{WOW_AGENT_ID:$a, WOW_ROLE:$r, WOW_ROOT:$w}')
    DESC="${ROLE} ${PURPOSE} — wrapped process"
    ;;
esac

jq -nc --arg c "$CMD" --argjson e "$ENV_JSON" --arg d "$DESC" --arg p "$PURPOSE" --arg f "$TRACKER_FIELD" \
  '{command:$c, env:$e, description:$d, purpose:$p, tracker_field:$f}'

exit 0
