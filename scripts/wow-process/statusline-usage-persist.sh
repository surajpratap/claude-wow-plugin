#!/usr/bin/env bash
# Story 172 — delegating statusline wrapper (opt-in; installed by M).
#
# CC exposes live `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`
# in exactly one place a process can observe it: the statusline command's stdin.
# This wrapper persists that data to a state file, then DELEGATES — pipes the
# same stdin to the consumer's recorded original statusline command and passes
# its stdout + exit code through unchanged, so the consumer's statusline is
# never degraded. The idle-limit-monitor polls the state file (Story 172 §3).
#
# Modes:
#   (default)              render-delegate: read stdin, persist if present, delegate.
#   --install <settings>   re-point settings.json .statusLine.command to this
#                          wrapper, recording the original (idempotent).
#   --uninstall <settings> restore the recorded original command (opt-out).
#
# bash-3.2-safe. State path: ${WOW_USAGE_STATE_FILE:-$ROOT/implementations/.wow-process/five-hour-usage.json}.
# Recorded original command for delegation: $WOW_STATUSLINE_ORIGINAL_CMD.

set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

resolve_root() {
  if [ -n "${WOW_ROOT:-}" ]; then printf '%s' "$WOW_ROOT"; return; fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"; return; fi
  printf '%s' "$(pwd)"
}

state_file_path() {
  if [ -n "${WOW_USAGE_STATE_FILE:-}" ]; then
    printf '%s' "$WOW_USAGE_STATE_FILE"
  else
    printf '%s/implementations/.wow-process/five-hour-usage.json' "$(resolve_root)"
  fi
}

install_wrapper() {
  local settings="$1"
  [ -f "$settings" ] || { echo "statusline-usage-persist: settings file not found: $settings" >&2; return 1; }
  local current
  current=$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null)
  case "$current" in
    *statusline-usage-persist.sh*)
      # Already active — idempotent no-op (do NOT re-record, which would
      # clobber the recorded original with the wrapper invocation).
      return 0
      ;;
  esac
  local tmp="$settings.tmp.$$"
  jq --arg wrapper "$SELF" --arg orig "$current" \
    '.statusLine.type = "command"
     | .statusLine.wowOriginalCommand = $orig
     | .statusLine.command = $wrapper' \
    "$settings" > "$tmp" && mv "$tmp" "$settings"
}

uninstall_wrapper() {
  local settings="$1"
  [ -f "$settings" ] || { echo "statusline-usage-persist: settings file not found: $settings" >&2; return 1; }
  local recorded
  recorded=$(jq -r '.statusLine.wowOriginalCommand // empty' "$settings" 2>/dev/null)
  local tmp="$settings.tmp.$$"
  if [ -n "$recorded" ]; then
    jq --arg orig "$recorded" \
      '.statusLine.command = $orig | del(.statusLine.wowOriginalCommand)' \
      "$settings" > "$tmp" && mv "$tmp" "$settings"
  else
    jq 'del(.statusLine.wowOriginalCommand)' "$settings" > "$tmp" && mv "$tmp" "$settings"
  fi
}

persist_usage() {
  local input="$1" state tmp
  state="$(state_file_path)"
  # Persist ONLY when the load-bearing field is present (API-key users / the
  # pre-first-response window have no rate_limits → write nothing).
  local present
  present=$(printf '%s' "$input" | jq -r 'try (.rate_limits.five_hour.used_percentage) catch null' 2>/dev/null)
  if [ -z "$present" ] || [ "$present" = "null" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$state")" 2>/dev/null || true
  tmp="$state.tmp.$$"
  if printf '%s' "$input" | jq -c \
      --argjson ts "$(date -u +%s)" \
      '{five_hour: {used_percentage: .rate_limits.five_hour.used_percentage,
                    resets_at: .rate_limits.five_hour.resets_at},
        seven_day: {used_percentage: .rate_limits.seven_day.used_percentage,
                    resets_at: .rate_limits.seven_day.resets_at},
        captured_ts: $ts}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$state"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

main() {
  case "${1:-}" in
    --install)   install_wrapper "${2:-}"; exit $? ;;
    --uninstall) uninstall_wrapper "${2:-}"; exit $? ;;
  esac

  local input
  input=$(cat)
  persist_usage "$input"

  local orig="${WOW_STATUSLINE_ORIGINAL_CMD:-}"
  if [ -z "$orig" ]; then
    # No recorded original (mis-install) — emit nothing, succeed cleanly so the
    # consumer's statusline is blank rather than erroring.
    exit 0
  fi
  printf '%s' "$input" | eval "$orig"
  exit $?
}

main "$@"
