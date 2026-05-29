#!/usr/bin/env bash
# Story 152 — checkpoint persistence for startup.sh resume protocol.
#
# Checkpoint file: ${ROOT}/implementations/.agents/<agent-id>.startup-state.json
# Shape: {phase, completed_phases, pending_answer_key, env_snapshot}
#
# Per-agent (not per-role) so concurrent role startups in one repo
# (e.g. multiple terminals) don't collide.

set -u

# write_checkpoint <agent-id> <phase> <pending-answer-key> <env-snapshot-json>
# completed_phases is read from the existing checkpoint (or [] if absent),
# then phase is appended-if-not-already-present.
write_checkpoint() {
  local agent_id="$1"
  local phase="$2"
  local pending_key="${3:-}"
  local env_json="${4:-}"
  [ -z "$env_json" ] && env_json='{}'
  local path="${WOW_ROOT}/implementations/.agents/${agent_id}.startup-state.json"
  mkdir -p "$(dirname "$path")"
  local completed='[]'
  if [ -f "$path" ]; then
    completed=$(jq -c '.completed_phases // []' "$path" 2>/dev/null || echo '[]')
  fi
  jq -nc \
    --arg phase "$phase" \
    --argjson completed "$completed" \
    --arg pending_key "$pending_key" \
    --argjson env_snapshot "$env_json" \
    '{phase: $phase,
      completed_phases: $completed,
      pending_answer_key: $pending_key,
      env_snapshot: $env_snapshot}' > "${path}.tmp"
  mv -f "${path}.tmp" "$path"
}

# mark_phase_complete <agent-id> <phase>
# Appends <phase> to completed_phases (idempotent).
mark_phase_complete() {
  local agent_id="$1"
  local phase="$2"
  local path="${WOW_ROOT}/implementations/.agents/${agent_id}.startup-state.json"
  [ -f "$path" ] || return 0
  jq --arg p "$phase" \
    '.completed_phases |= (. + [$p] | unique)' "$path" > "${path}.tmp"
  mv -f "${path}.tmp" "$path"
}

# read_checkpoint <agent-id>
# Prints the checkpoint JSON; empty + exit 1 if missing.
read_checkpoint() {
  local agent_id="$1"
  local path="${WOW_ROOT}/implementations/.agents/${agent_id}.startup-state.json"
  if [ ! -f "$path" ]; then
    return 1
  fi
  cat "$path"
}

# validate_answer <expected-key> <actual-key>
# Returns 0 if matches; non-zero (writes diagnostic to stderr) if not.
validate_answer() {
  local expected="$1"
  local actual="$2"
  if [ "$expected" = "$actual" ]; then
    return 0
  fi
  echo "[startup-checkpoint] answer key mismatch: expected '$expected', got '$actual'" >&2
  return 1
}

# remove_checkpoint <agent-id>
# Best-effort cleanup at startup completion.
remove_checkpoint() {
  local agent_id="$1"
  local path="${WOW_ROOT}/implementations/.agents/${agent_id}.startup-state.json"
  rm -f "$path" 2>/dev/null || true
}
