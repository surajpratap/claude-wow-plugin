#!/usr/bin/env bash
# Story 152 — phase_bootstrap.
# Resolve agent ID (idempotent on claude_pid); claim role marker; init
# tracker JSON; emit hello via MCP CLI; emit arm-monitor instructions
# per role (using build_arm_monitor_command from lib_emit.sh which
# honors story-154's monitor-pipe.sh downstream pipe + empty-PIPE
# fallback).

phase_bootstrap() {
  local role="$1"

  # 1. Resolve agent ID idempotently (calls scripts/wow-existing-agent-id.sh)
  local existing_id agent_id
  local existing_helper
  existing_helper=$(wow-locate scripts/wow-existing-agent-id.sh 2>/dev/null || true)
  if [ -n "$existing_helper" ]; then
    existing_id=$(bash "$existing_helper" "$role" 2>/dev/null || true)
  fi
  if [ -n "${existing_id:-}" ]; then
    agent_id="$existing_id"
    emit_info "bootstrap: reusing existing agent id $agent_id"
  else
    local ts hex
    ts=$(date -u +%Y%m%dT%H%M%S)
    hex=$(openssl rand -hex 3 2>/dev/null || printf '%06x' $((RANDOM * RANDOM)))
    agent_id="${role}-${ts}-${hex}"
    emit_info "bootstrap: generated fresh agent id $agent_id"
  fi
  export WOW_AGENT_ID="$agent_id"

  # 2. Claim role marker (best-effort; whats-my-role.sh exits 0 on success)
  local wmr
  wmr=$(wow-locate scripts/whats-my-role.sh 2>/dev/null || true)
  if [ -n "$wmr" ]; then
    # shellcheck disable=SC1090
    . "$wmr" 2>/dev/null || true
    wow_claim_role "$role" 2>/dev/null || true
    emit_info "bootstrap: role marker claimed for $role"
  fi

  # 3. Init tracker JSON
  local tracker="${WOW_ROOT}/implementations/.agents/${agent_id}.json"
  mkdir -p "$(dirname "$tracker")"
  if [ ! -f "$tracker" ]; then
    local now claude_pid
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    claude_pid="${PPID:-0}"
    jq -nc --argjson ll 0 --arg ls "$now" --argjson pid "$claude_pid" \
      '{last_line: $ll, last_seen: $ls, claude_pid: $pid}' > "$tracker"
    emit_info "bootstrap: tracker initialized at $tracker"
  fi

  # 4. Emit `hello` via MCP CLI (best-effort; if MCP server CLI unavailable,
  #    the hello is skipped — the role can still arm monitors and start
  #    listening; full hello will land on the role's first explicit emit)
  local mcp_server
  mcp_server=$(wow-locate mcp/claude-wow-server/server.py 2>/dev/null || true)
  if [ -n "$mcp_server" ]; then
    python3 "$mcp_server" --exec bus-emit \
      "{\"from\":\"$agent_id\",\"to\":\"*\",\"type\":\"hello\",\"payload\":\"${role} online via startup.sh\"}" \
      2>/dev/null || emit_info "bootstrap: hello emit via MCP CLI failed (non-fatal)"
  fi

  # 5. Emit arm-monitor instructions per role.
  # FINDING-42 fix (bug 0003): each helper's non-zero return MUST
  # propagate. v3.29.0 cascaded past arm-helper failure all the way to
  # emit_complete, leaving CC with a successful `complete` it should
  # never have seen.
  case "$role" in
    manager)
      _emit_bus_tail_arm "$role" "$agent_id" || return 1
      _emit_idle_monitor_arm "$role" || return 1
      _emit_github_bridge_arm_if_configured "$role" || return 1
      ;;
    senior-developer|pair-programmer|tester|slacker)
      _emit_bus_tail_arm "$role" "$agent_id" || return 1
      ;;
  esac

  # 6. Emit `complete` with the expected monitor list for --verify.
  # FINDING-42 fix (bug 0003): emit_complete itself can fail (jq error,
  # closed stdout) — abort + return 1 instead of pretending success.
  local expect_monitors_json
  case "$role" in
    manager)
      if [ -f "${WOW_ROOT}/implementations/.github/config.json" ]; then
        expect_monitors_json='["bus-tail","idle-monitor","github-bridge"]'
      else
        expect_monitors_json='["bus-tail","idle-monitor"]'
      fi
      ;;
    *)
      expect_monitors_json='["bus-tail"]'
      ;;
  esac
  if ! emit_complete "$agent_id" "$tracker" "$expect_monitors_json"; then
    emit_abort "emit_complete failed (jq error or stdout unavailable)" ""
    return 1
  fi
  return 0
}

# FINDING-42 fix (bug 0003): each helper checks BOTH build_arm_monitor_command
# AND emit_arm_monitor return codes, emits abort on either failure, returns 1.
# Callers in phase_bootstrap propagate via `|| return 1`.

_emit_bus_tail_arm() {
  local role="$1"
  local agent_id="$2"
  local bus="${WOW_ROOT}/implementations/.message-bus.jsonl"
  local cmd
  if ! cmd=$(build_arm_monitor_command "bus-tail" "\"$bus\" \"$agent_id\" \"$role\""); then
    emit_abort "bus-tail wrapper not resolvable via wow-locate" ""
    return 1
  fi
  if ! emit_arm_monitor "bus-tail" "$cmd" "$role bus tail" "true" "3600000"; then
    emit_abort "emit_arm_monitor failed for bus-tail (jq error?)" ""
    return 1
  fi
  return 0
}

_emit_idle_monitor_arm() {
  local role="$1"
  local cmd
  if ! cmd=$(build_arm_monitor_command "idle-monitor" ""); then
    emit_abort "idle-monitor wrapper not resolvable" ""
    return 1
  fi
  if ! emit_arm_monitor "idle-monitor" "$cmd" "idle monitor" "true" "3600000"; then
    emit_abort "emit_arm_monitor failed for idle-monitor (jq error?)" ""
    return 1
  fi
  return 0
}

_emit_github_bridge_arm_if_configured() {
  local role="$1"
  local config="${WOW_ROOT}/implementations/.github/config.json"
  if [ ! -f "$config" ]; then
    emit_info "bootstrap: github bridge config absent — skipping arm-monitor"
    return 0
  fi
  local cmd
  if ! cmd=$(build_arm_monitor_command "github-bridge" "--config \"$config\""); then
    emit_abort "github-bridge wrapper not resolvable" ""
    return 1
  fi
  if ! emit_arm_monitor "github-bridge" "$cmd" "github bridge" "true" "3600000"; then
    emit_abort "emit_arm_monitor failed for github-bridge (jq error?)" ""
    return 1
  fi
  return 0
}
