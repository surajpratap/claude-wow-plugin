#!/usr/bin/env bash
# fswatch-peer.sh — wrap fswatch with PID-uniqueness for peer roles (PP/T).
#
# Usage: fswatch-peer.sh <repo-root> [<extra-exclude-pattern>]...
#
# Loads ${WOW_ROOT}/implementations/.wow-process/fswatch-peer.conf if present:
#   FSWATCH_EXCLUDES=( '<pattern>' '<pattern>' ... )
# bash array of regex exclude patterns (passed to `fswatch -e`).
# Conflict policy: kill (plugin-spawned only; stale = prior session leak).

set -u

ROOT_ARG="${1:?repo root required (arg 1)}"; shift

PURPOSE="fswatch-peer"
CONFLICT_POLICY="kill"
WOW_ROOT="${WOW_ROOT:-$ROOT_ARG}"
WOW_ROLE="${WOW_ROLE:-pair-programmer}"
WOW_PROCESS_DIR="${WOW_ROOT}/implementations/.wow-process"
PIDFILE="${WOW_PROCESS_DIR}/${PURPOSE}-${WOW_ROLE}.pid"

FSWATCH_EXCLUDES=(
  '/node_modules/'
  '/\.git/'
  '\.message-bus\.jsonl$'
  '/\.agents/'
  '/\.claude/'
  '/implementations/\.github/'
  '\.review\.txt$'
)

CONF="${WOW_PROCESS_DIR}/${PURPOSE}.conf"
[ -f "$CONF" ] && . "$CONF"

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

EXCLUDE_FLAGS=()
for pat in "${FSWATCH_EXCLUDES[@]}"; do
  EXCLUDE_FLAGS+=(-e "$pat")
done
for extra in "$@"; do
  EXCLUDE_FLAGS+=(-e "$extra")
done

echo "[fswatch-armed] on $WOW_ROOT" >&2
exec fswatch -r -E "${EXCLUDE_FLAGS[@]}" --format '[changed] %p' "$WOW_ROOT"
