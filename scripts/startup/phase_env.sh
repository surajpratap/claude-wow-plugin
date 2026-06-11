#!/usr/bin/env bash
# Story 152 — phase_env.
# Discovers ROOT, CANONICAL_BRANCH, TEAM. Reads .my-team (or emits
# ask-human for team-claim, M-only). Universal — runs for every role.

phase_env() {
  local role="$1"
  # ROOT is already exported by startup.sh.
  emit_info "env: ROOT=${WOW_ROOT}"

  local canonical_branch
  canonical_branch=$(git -C "$WOW_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "main")
  emit_info "env: canonical_branch=${canonical_branch}"

  local my_team_file="${WOW_ROOT}/implementations/.my-team"
  if [ -f "$my_team_file" ]; then
    local team
    team=$(tr -d '[:space:]' < "$my_team_file")
    emit_info "env: team=${team}"
    export WOW_TEAM="$team"
  else
    if [ "$role" = "manager" ]; then
      # Only M handles the team-claim flow; SD/PP/T/S inherit the
      # team from the repo's .my-team file (which M creates).
      emit_info "env: .my-team absent — M's phase_env would emit team-claim ask-human here (deferred; team flow not script-tested in this story)"
    else
      emit_info "env: .my-team absent (M will populate)"
    fi
  fi

  # Current project mode (implementations/config.json) — every role's startup
  # doctrine keys on this line to re-orient mid-AHOD after a restart. Sibling
  # path, not wow-locate: a freshly-shipped helper must resolve from THIS
  # plugin version, not a stale install cache.
  local config_mode
  config_mode=$(bash "$SCRIPT_DIR/wow-config.sh" get .mode 2>/dev/null) || config_mode=""
  [ -n "$config_mode" ] || config_mode="default"
  emit_info "env: mode=${config_mode}"
  return 0
}
