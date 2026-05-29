#!/usr/bin/env bash
# Bug 0002, Layer A — per-wrapper self-throttle.
#
# Every long-running wrapper script sources this file + calls
# wow_spawn_check before each child-spawn. The check counts recent
# spawns in an in-process ring buffer; on overshoot it logs to stderr
# and forces exit non-zero.
#
# Defaults:
#   WOW_RUNTIME_SPAWN_WINDOW_S = 2   (rolling window in seconds)
#   WOW_RUNTIME_SPAWN_MAX      = 5   (max spawns per window)
#
# Both env-tunable for projects with legitimate high-frequency wrappers.
#
# Usage from a wrapper script:
#   . "$(dirname "$0")/spawn-rate-limit.sh"
#   wow_spawn_check "<purpose-tag-for-stderr-msg>" || exit 2
#   <spawn child>
#
# Caller is responsible for exiting; this function returns 0 on
# allow-spawn or 2 on overshoot (sets nothing else — stderr only).
#
# The ring buffer is process-local (a bash array). Each wrapper
# instance has its own ring; that's correct — Layer A targets a
# single wrapper looping on itself.

# Initialize ring once per shell.
if [ -z "${_WOW_SPAWN_RING_INIT:-}" ]; then
  _WOW_SPAWN_RING=()
  _WOW_SPAWN_RING_INIT=1
fi

wow_spawn_check() {
  local purpose="${1:-unknown}"
  local window_s="${WOW_RUNTIME_SPAWN_WINDOW_S:-2}"
  local max="${WOW_RUNTIME_SPAWN_MAX:-5}"

  local now
  now=$(date +%s)
  local cutoff=$(( now - window_s ))

  # Prune entries older than cutoff. Bash empty-array expansion under
  # `set -u` errors with "unbound variable" — guard via length check.
  local pruned=()
  local entry
  if [ "${#_WOW_SPAWN_RING[@]}" -gt 0 ]; then
    for entry in "${_WOW_SPAWN_RING[@]}"; do
      if [ "$entry" -gt "$cutoff" ]; then
        pruned+=("$entry")
      fi
    done
  fi
  if [ "${#pruned[@]}" -gt 0 ]; then
    _WOW_SPAWN_RING=("${pruned[@]}")
  else
    _WOW_SPAWN_RING=()
  fi

  # Check count.
  if [ "${#_WOW_SPAWN_RING[@]}" -ge "$max" ]; then
    printf '[wow-process:%s:circuit-breaker] EXIT_SPAWN_RATE >=%d re-spawns in %ds — refusing to continue. Likely a misbehaving consumer environment.\n' \
      "$purpose" "$max" "$window_s" >&2
    return 2
  fi

  # Record this spawn.
  _WOW_SPAWN_RING+=("$now")
  return 0
}
