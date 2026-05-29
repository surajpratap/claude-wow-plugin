#!/usr/bin/env bash
# Story 158 — startup phase: trigger consolidate-memory.sh when CC's memory
# dir has files newer than the role's learnings file. Runs immediately
# BEFORE phase_bootstrap (which emits `complete`) so any `info` lines land
# before startup finishes.
#
# Emits JSONL action lines per startup.sh's closed enum. Always emits at
# least one `info` describing the decision (trigger / skip / no-memory-dir).
# Never blocks startup — a consolidation hiccup logs + skips.

phase_memory_consolidation() {
  local role="$1"
  local script
  # WOW_CONSOLIDATE_SCRIPT is a test seam; production resolves via wow-locate.
  script="${WOW_CONSOLIDATE_SCRIPT:-}"
  if [ -z "$script" ]; then
    script=$(wow-locate scripts/consolidate-memory.sh 2>/dev/null || true)
  fi
  if [ -z "$script" ] || [ ! -f "$script" ]; then
    emit_info "consolidation: skip (consolidate-memory.sh not resolvable)"
    return 0
  fi

  local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local encoded
  encoded=$(echo "$WOW_ROOT" | sed 's|/|-|g')
  local memory_dir="${config_dir}/projects/${encoded}/memory"
  local learnings_file="${WOW_ROOT}/implementations/learnings/${role}.md"

  if [ ! -d "$memory_dir" ]; then
    emit_info "consolidation: skip (no memory dir at $memory_dir)"
    return 0
  fi

  # mtime check: any *.md in memory_dir newer than learnings_file? If
  # learnings_file doesn't exist, treat as "trigger".
  local trigger=0
  if [ ! -f "$learnings_file" ]; then
    trigger=1
  else
    if find "$memory_dir" -maxdepth 1 -name '*.md' -newer "$learnings_file" 2>/dev/null | grep -q .; then
      trigger=1
    fi
  fi

  if [ "$trigger" -eq 0 ]; then
    emit_info "consolidation: skip (no memory file newer than learnings)"
    return 0
  fi

  emit_info "consolidation: trigger (running consolidate-memory.sh $role)"
  local summary
  summary=$(bash "$script" "$role" 2>/dev/null || true)
  if [ -n "$summary" ]; then
    emit_info "consolidation: $summary"
  else
    emit_info "consolidation: ran but produced no summary (treating as no-op)"
  fi
  return 0
}
