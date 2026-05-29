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
  return 0
}
