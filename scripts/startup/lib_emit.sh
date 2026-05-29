#!/usr/bin/env bash
# Story 152 — startup.sh emit helpers. Closed action enum at the
# function boundary: the only way to emit an action line is via one of
# these 5 functions, and each one hardcodes its action verb. The
# original symptom (backlog 190) — agents reaching for ScheduleWakeup /
# /loop for bus-tail — is closed by construction: there's no
# emit_schedule_wakeup function.
#
# Every function prints exactly one JSON object on stdout (jq -nc).
# Caller's stderr is left untouched; debugging info goes to stderr
# (never stdout, which is the CC-handoff stream).

set -u

emit_info() {
  local text="$1"
  jq -nc --arg action info --arg text "$text" \
    '{action: $action, text: $text}'
}

emit_arm_monitor() {
  local purpose="$1"
  local command="$2"
  local description="$3"
  local persistent="${4:-true}"
  local timeout_ms="${5:-3600000}"
  jq -nc \
    --arg action arm-monitor \
    --arg purpose "$purpose" \
    --arg command "$command" \
    --arg description "$description" \
    --argjson persistent "$persistent" \
    --argjson timeout_ms "$timeout_ms" \
    '{action: $action, purpose: $purpose,
      spec: {command: $command, description: $description,
             persistent: $persistent, timeout_ms: $timeout_ms}}'
}

emit_ask_human() {
  local question="$1"
  local header="$2"
  local options_json="$3"
  local checkpoint_key="$4"
  jq -nc \
    --arg action ask-human \
    --arg question "$question" \
    --arg header "$header" \
    --argjson options "$options_json" \
    --arg checkpoint_key "$checkpoint_key" \
    '{action: $action, question: $question, header: $header,
      options: $options, checkpoint_key: $checkpoint_key}'
}

emit_complete() {
  local agent_id="$1"
  local tracker_path="$2"
  local expect_monitors_json="$3"
  jq -nc \
    --arg action complete \
    --arg agent_id "$agent_id" \
    --arg tracker_path "$tracker_path" \
    --argjson expect_monitors "$expect_monitors_json" \
    '{action: $action, agent_id: $agent_id,
      tracker_path: $tracker_path,
      expect_monitors: $expect_monitors}'
}

emit_abort() {
  local reason="$1"
  local ascii_block="${2:-}"
  jq -nc \
    --arg action abort \
    --arg reason "$reason" \
    --arg ascii_block "$ascii_block" \
    '{action: $action, reason: $reason, ascii_block: $ascii_block}'
}

# Helper used by phase_bootstrap.sh to construct the Monitor command
# for a given purpose, honoring story 154's monitor-pipe.sh downstream
# pipe + the empty-PIPE fallback. Returns 0 + prints the command on
# success; returns 1 on failure (neither wrap script nor pipe
# resolvable — caller should emit_abort).
build_arm_monitor_command() {
  local purpose="$1"
  local extra_args="${2:-}"
  local wrap_script
  wrap_script=$(wow-locate "scripts/wow-process/${purpose}.sh" 2>/dev/null || true)
  # Bug 0007 fallback (Story 163): for monitor-pipe.sh ONLY, fall back
  # to this lib's sibling layout when wow-locate fails. wow-locate may
  # resolve to an older cached plugin version that lacks
  # monitor-pipe.sh (introduced in 154); without this, the pipe-wrap
  # silently degrades to the no-pipe form even in a current install.
  # The wrap_script lookup intentionally does NOT have a fallback —
  # tests rely on `wow-locate <wrap>` returning empty to simulate
  # wrap-unresolvable failure (Bug 0003 FINDING-42 guard).
  local pipe
  pipe=$(wow-locate scripts/wow-process/monitor-pipe.sh 2>/dev/null || true)
  if [ -z "$pipe" ] || [ ! -f "$pipe" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local fallback_pipe="$lib_dir/../wow-process/monitor-pipe.sh"
    [ -f "$fallback_pipe" ] && pipe="$fallback_pipe"
  fi
  if [ -n "$wrap_script" ] && [ -n "$pipe" ]; then
    if [ -n "$extra_args" ]; then
      printf 'bash "%s" %s | bash "%s" --purpose %s' \
        "$wrap_script" "$extra_args" "$pipe" "$purpose"
    else
      printf 'bash "%s" | bash "%s" --purpose %s' \
        "$wrap_script" "$pipe" "$purpose"
    fi
  elif [ -n "$wrap_script" ]; then
    if [ -n "$extra_args" ]; then
      printf 'exec bash "%s" %s' "$wrap_script" "$extra_args"
    else
      printf 'exec bash "%s"' "$wrap_script"
    fi
  else
    return 1
  fi
}
