#!/usr/bin/env bash
# github-bridge.sh — wrap python3 bridge/github/run.py with PID-uniqueness.
#
# Usage: github-bridge.sh --config <path> [...other args passed to run.py]
#
# Loads ${WOW_ROOT}/implementations/.wow-process/github-bridge.conf if present:
#   BRIDGE_SCRIPT=<absolute path to bridge/github/run.py>
# Defaults: locate bridge/github/run.py via plugin-cache fallback.
# Conflict policy: raise (port-binding; conflict might be a human's debug
# instance — surface to caller via exit 2).

set -u

PURPOSE="github-bridge"
CONFLICT_POLICY="raise"
WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WOW_ROLE="${WOW_ROLE:-manager}"
WOW_PROCESS_DIR="${WOW_ROOT}/implementations/.wow-process"
PIDFILE="${WOW_PROCESS_DIR}/${PURPOSE}-${WOW_ROLE}.pid"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BRIDGE_SCRIPT="${BRIDGE_SCRIPT:-$(
  ls "$WOW_ROOT/.claude/bridge/github/run.py" 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/bridge/github/run.py 2>/dev/null | head -1
)}"

CONF="${WOW_PROCESS_DIR}/${PURPOSE}.conf"
[ -f "$CONF" ] && . "$CONF"

if [ -z "${BRIDGE_SCRIPT:-}" ] || [ ! -f "$BRIDGE_SCRIPT" ]; then
  echo "[wow-process:${PURPOSE}] bridge script not found (looked in project .claude/ and plugin cache)" >&2
  exit 5
fi

if [ -f "$PIDFILE" ]; then
  PRIOR_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "${PRIOR_PID:-}" ] && kill -0 "$PRIOR_PID" 2>/dev/null; then
    case "$CONFLICT_POLICY" in
      kill)
        kill -TERM "$PRIOR_PID" 2>/dev/null || true
        sleep 2
        kill -0 "$PRIOR_PID" 2>/dev/null && kill -KILL "$PRIOR_PID" 2>/dev/null || true
        ;;
      raise)
        echo "[wow-process:${PURPOSE}] conflict: PID $PRIOR_PID alive; refusing to spawn" >&2
        exit 2
        ;;
    esac
  fi
fi

mkdir -p "$WOW_PROCESS_DIR"
echo "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
trap 'rm -f "$PIDFILE"; exit 130' INT TERM

exec python3 "$BRIDGE_SCRIPT" "$@"
