#!/usr/bin/env bash
# Story 152 — mechanical agent startup.
#
# Usage:
#   bash startup.sh --role <manager|senior-developer|pair-programmer|tester|slacker>
#   bash startup.sh --resume --answer <checkpoint-key>=<value>
#   bash startup.sh --verify
#
# Emits one JSONL action line per scriptable step on stdout. Closed
# action enum: {info, arm-monitor, ask-human, complete, abort}. The
# enum has NO schedule-wakeup or start-loop value — closes backlog 190
# by construction (the script literally cannot tell CC to use a
# scheduler for bus-tail).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STARTUP_LIB_DIR="$SCRIPT_DIR/startup"

# Story 184 — worktree-invariant ROOT (whats-my-role.sh idiom): $WOW_ROOT first,
# else the shared --git-common-dir parent. Never --show-toplevel (worktree root).
if [ -z "${WOW_ROOT:-}" ]; then
  WOW_ROOT=$(pwd)
  if _wow_gcd=$(git rev-parse --git-common-dir 2>/dev/null); then
    case "$_wow_gcd" in /*) ;; *) _wow_gcd="$(pwd)/$_wow_gcd" ;; esac
    WOW_ROOT=$(cd "$(dirname "$_wow_gcd")" 2>/dev/null && pwd) || WOW_ROOT=$(pwd)
  fi
  unset _wow_gcd
fi
export WOW_ROOT

# shellcheck source=startup/lib_emit.sh
. "$STARTUP_LIB_DIR/lib_emit.sh"
# shellcheck source=startup/lib_checkpoint.sh
. "$STARTUP_LIB_DIR/lib_checkpoint.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  startup.sh --role <manager|senior-developer|pair-programmer|tester|slacker>
  startup.sh --resume --answer <key>=<value>
  startup.sh --verify
EOF
}

MODE=""
ROLE=""
ANSWER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --role)    MODE="run"; ROLE="${2:-}"; shift 2 ;;
    --resume)  MODE="resume"; shift ;;
    --answer)  ANSWER="${2:-}"; shift 2 ;;
    --verify)  MODE="verify"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[startup] unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

VALID_ROLES="manager senior-developer pair-programmer tester slacker"

validate_role() {
  local r="$1"
  case " $VALID_ROLES " in
    *" $r "*) return 0 ;;
    *) echo "[startup] invalid --role: '$r'. Valid: $VALID_ROLES" >&2
       return 2 ;;
  esac
}

phases_for_role() {
  # Story 158: `memory_consolidation` slots immediately BEFORE `bootstrap` for
  # every role. bootstrap emits `complete`; consolidation must precede so any
  # consolidation `info` lines land before the agent is told startup is done.
  case "$1" in
    manager)          echo "env layout version sweep coherence peer memory_consolidation bootstrap" ;;
    senior-developer) echo "env memory_consolidation bootstrap" ;;
    pair-programmer)  echo "env memory_consolidation bootstrap" ;;
    tester)           echo "env memory_consolidation bootstrap" ;;
    slacker)          echo "env memory_consolidation bootstrap" ;;
    *) return 1 ;;
  esac
}

run_phases() {
  local role="$1"
  local phases
  phases=$(phases_for_role "$role") || {
    emit_abort "invalid role: $role" ""
    return 2
  }
  for phase in $phases; do
    local phase_file="$STARTUP_LIB_DIR/phase_${phase}.sh"
    if [ ! -f "$phase_file" ]; then
      emit_abort "phase library missing: $phase_file" ""
      return 1
    fi
    # shellcheck disable=SC1090
    . "$phase_file"
    # FINDING-40 fix (bug 0003): the prior `if ! phase_X; then return 0; fi`
    # form silently converted ANY phase failure into a successful startup,
    # which let agents complete startup with broken state. The case
    # statement makes the contract explicit:
    #   rc=0  → phase OK, continue
    #   rc=10 → clean ask-human handoff; CC re-invokes via --resume
    #   else  → genuine failure → emit_abort + non-zero exit
    "phase_${phase}" "$role"
    local rc=$?
    case "$rc" in
      0)
        mark_phase_complete "${WOW_AGENT_ID:-pending}" "$phase"
        ;;
      10)
        return 0
        ;;
      *)
        emit_abort "phase $phase failed with rc=$rc" ""
        return 1
        ;;
    esac
  done
}

verify_monitors() {
  local role
  local wmr
  wmr=$(wow-locate scripts/whats-my-role.sh 2>/dev/null || true)
  if [ -n "$wmr" ]; then
    role=$(bash "$wmr" whats-my-role 2>/dev/null || true)
  fi
  if [ -z "${role:-}" ]; then
    echo "[startup --verify] role marker not found" >&2
    return 3
  fi
  local agent_id
  agent_id=$(ls -t "${WOW_ROOT}/implementations/.agents/${role}-"*.json 2>/dev/null \
    | head -1 | sed 's|.*/||; s|\.json$||')
  if [ -z "$agent_id" ]; then
    echo "[startup --verify] no tracker for role $role" >&2
    return 3
  fi
  local tracker="${WOW_ROOT}/implementations/.agents/${agent_id}.json"
  local wow_process_dir="${WOW_ROOT}/implementations/.wow-process"

  # FINDING-43 fix (bug 0003): a fresh tracker with zero *_task_id keys
  # iterated the loop below zero times → missing=0 → return 0. Agents
  # passed `--verify` having armed no Monitors at all, defeating story
  # 152's closed-action-enum guarantee. Compute expected purposes from
  # role-process-map.json for this role; reject if tracker has zero
  # *_task_id entries AND any required purpose is expected.
  local role_map
  role_map=$(wow-locate scripts/wow-process/role-process-map.json 2>/dev/null || true)
  if [ -n "$role_map" ] && [ -f "$role_map" ]; then
    local expected_purposes
    expected_purposes=$(jq -r --arg role "$role" '.[$role] // [] | map(select(endswith("?") | not)) | .[]' "$role_map" 2>/dev/null)
    local required=()
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      if [ "$p" = "github-bridge" ] && [ ! -f "${WOW_ROOT}/implementations/.github/config.json" ]; then
        continue
      fi
      required+=("$p")
    done <<< "$expected_purposes"
    local task_id_count
    task_id_count=$(jq -r '[to_entries[] | select(.key | endswith("_task_id"))] | length' "$tracker" 2>/dev/null)
    if [ "${#required[@]}" -gt 0 ] && [ "${task_id_count:-0}" -eq 0 ]; then
      local req_json
      req_json=$(printf '%s\n' "${required[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
      printf 'EXIT_NO_MONITORS_ARMED\t%s\texpected: %s\n' "$role" "$req_json" >&2
      return 1
    fi
  fi

  local missing=0
  while IFS= read -r purpose; do
    [ -z "$purpose" ] && continue
    local pidfile="${wow_process_dir}/${purpose}-${role}.pid"
    local pid=""
    if [ -f "$pidfile" ]; then
      pid=$(tr -d '[:space:]' < "$pidfile" 2>/dev/null)
    fi
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      local rearm_cmd
      rearm_cmd=$(build_arm_monitor_command "$purpose" 2>/dev/null || echo "<unresolvable>")
      local spec_json
      spec_json=$(jq -nc --arg command "$rearm_cmd" \
        --arg description "$role $purpose" \
        '{command: $command, description: $description, persistent: true, timeout_ms: 3600000}')
      printf 'EXIT_MISSING_MONITOR\t%s\t%s\n' "$purpose" "$spec_json" >&2
      missing=$((missing+1))
    fi
  done < <(jq -r 'to_entries[] | select(.key | endswith("_task_id")) | (.key | sub("_task_id$"; "") | gsub("_"; "-"))' "$tracker" 2>/dev/null)

  if [ "$missing" -gt 0 ]; then
    return 1
  fi
  return 0
}

case "$MODE" in
  run)
    if ! validate_role "$ROLE"; then exit 2; fi
    run_phases "$ROLE"
    ;;
  resume)
    if [ -z "$ANSWER" ]; then
      echo "[startup --resume] requires --answer <key>=<value>" >&2
      exit 2
    fi
    latest=$(ls -t "${WOW_ROOT}/implementations/.agents/"*.startup-state.json 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
      echo "[startup --resume] no checkpoint found" >&2
      exit 1
    fi
    role_from_ckpt=$(jq -r '.env_snapshot.role // empty' "$latest" 2>/dev/null)
    if [ -z "$role_from_ckpt" ]; then
      echo "[startup --resume] checkpoint missing env_snapshot.role" >&2
      exit 1
    fi
    answer_key="${ANSWER%%=*}"
    answer_value="${ANSWER#*=}"
    jq --arg k "$answer_key" --arg v "$answer_value" \
      '.env_snapshot[$k] = $v | .pending_answer_key = ""' "$latest" > "${latest}.tmp"
    mv -f "${latest}.tmp" "$latest"
    run_phases "$role_from_ckpt"
    ;;
  verify)
    verify_monitors
    ;;
  *)
    usage
    exit 2
    ;;
esac
