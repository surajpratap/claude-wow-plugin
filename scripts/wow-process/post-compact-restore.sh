#!/usr/bin/env bash
# Story 072 / extended Story 105 — post-compact process-restore helper.
#
# Reads the agent's tracker JSON to discover which Monitors were actually
# armed pre-compaction (tracker-driven detection; the role-process-map
# serves only as a sanity-check intersection), then for each emits one line:
#   ALIVE <purpose> <pid>                                     — PID file alive
#   MISSING\t<purpose>\t<script-path>\t<tracker-field>         — tab-separated
#
# Agent parses the MISSING line, invokes monitor-spec.sh <purpose> for the
# JSON re-arm spec, calls Monitor with that spec, then writes the new
# task_id back via monitor-rearm-record.sh.
#
# If the tracker can't be resolved (tracker-armed-purposes.sh exit 2), this
# script falls back to the legacy role-process-map walk and prints a stderr
# warning — preserves behaviour for agents without a tracker yet.
#
# Exit codes: 0 success, 2 map file missing/unreadable, 3 role marker missing.

set -u

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Story 133: resolve role via whats-my-role.sh, NOT a fixed-path
# .claude-plugin/current-role file (no script writes that path). The real
# marker is per-claude-PID under .claude/.session-role-by-claude-pid/<pid>.
# $WOW_ROLE_OVERRIDE is a test-only knob: when set, skip the helper walk
# (whose PPID-walk needs a claude ancestor, unavailable from test subshells).
ROLE="${WOW_ROLE_OVERRIDE:-}"
if [ -z "$ROLE" ]; then
  WMR="$(wow-locate scripts/whats-my-role.sh 2>/dev/null || echo "$SCRIPT_DIR/../whats-my-role.sh")"
  ROLE=$(bash "$WMR" whats-my-role 2>/dev/null || true)
fi

if [ -z "$ROLE" ]; then
  echo "[post-compact-restore] role marker not found (no .claude/.session-role-by-claude-pid/<pid> for this session)" >&2
  exit 3
fi

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MAP=$(
  ls "${WOW_ROOT}/.claude/scripts/wow-process/role-process-map.json" 2>/dev/null \
  || ls "${WOW_ROOT}/scripts/wow-process/role-process-map.json" 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/role-process-map.json 2>/dev/null | head -1
)

if [ -z "$MAP" ] || [ ! -f "$MAP" ]; then
  echo "[post-compact-restore] role-process-map.json not found" >&2
  exit 2
fi

# Story 105 — tracker-driven detection. Story 126: the fallback
# fires ONLY when the tracker file is not resolvable (rc=2 from the helper),
# NOT on empty content (rc=0 with empty stdout is a legitimate "zero armed
# purposes" state — re-arming a default cohort there would invert 105's
# tracker-is-source-of-truth design and spawn Monitors the agent never asked
# for). Other helper failures (e.g. rc=3 role-marker-missing) silently no-op;
# the loop below iterates zero purposes and the restore script emits nothing.
ARMED=$(bash "$SCRIPT_DIR/tracker-armed-purposes.sh" 2>/dev/null)
ARMED_RC=$?
if [ "$ARMED_RC" -eq 2 ]; then
  echo "[post-compact-restore] tracker not found — falling back to role-process-map walk" >&2
  ARMED=$(jq -r --arg r "$ROLE" '.[$r] // [] | .[]' "$MAP" 2>/dev/null || true)
fi

WOW_PROCESS_DIR="${WOW_ROOT}/implementations/.wow-process"

# Story 154: role-process-map entries may carry a trailing '?' to flag
# conditional purposes (slack-bridge-spawn?, slack-events-feed?). The '?'
# is a map-level flag only — strip before every downstream use (purpose
# name, pidfile path, wrapper-script lookup, tracker-field name, monitor-
# spec.sh invocation). The presence of the '?' here is the trigger for
# the creds-presence gate below.
for p_raw in $ARMED; do
  # Strip trailing '?' to get the canonical purpose name.
  case "$p_raw" in
    *\?) p="${p_raw%?}"; conditional=1 ;;
    *)   p="$p_raw"; conditional=0 ;;
  esac

  # Sanity-check: drop purposes not allowed for this role. Matches both
  # `<purpose>` and `<purpose>?` in the map so the predicate sees the
  # raw form.
  if ! jq -e --arg r "$ROLE" --arg p "$p" '.[$r] // [] | any((. | rtrimstr("?")) == $p)' "$MAP" >/dev/null 2>&1; then
    continue
  fi

  # Creds-presence gate for conditional purposes. Slack purposes require
  # the bridge to be provisioned (a .bridge-pid present in
  # implementations/.slack/); if absent, the purpose is N/A and we emit
  # nothing.
  if [ "$conditional" -eq 1 ]; then
    case "$p" in
      slack-bridge-spawn|slack-events-feed)
        if [ ! -f "${WOW_ROOT}/implementations/.slack/.bridge-pid" ]; then
          continue
        fi
        ;;
      *)
        # Future conditional purposes: add their creds gate here. Default
        # to skipping unknown conditional purposes so we never emit a
        # MISSING line we can't follow up on.
        continue
        ;;
    esac
  fi

  PIDFILE="${WOW_PROCESS_DIR}/${p}-${ROLE}.pid"
  if [ -f "$PIDFILE" ]; then
    PID=$(tr -d '[:space:]' < "$PIDFILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      echo "ALIVE $p $PID"
      continue
    fi
  fi
  WRAP="${SCRIPT_DIR}/${p}.sh"
  FIELD="$(echo "$p" | tr '-' '_')_task_id"
  printf 'MISSING\t%s\t%s\t%s\n' "$p" "$WRAP" "$FIELD"
done

exit 0
