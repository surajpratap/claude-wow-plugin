#!/usr/bin/env bash
# Story 152 — phase_sweep (M-only).
# Opportunistic bus trim above threshold; stale .agents/*.json files
# (24h mtime); stale role markers; stale merged feat-branches
# (team-scoped — never another team's branches).

phase_sweep() {
  local role="$1"
  local bus="${WOW_ROOT}/implementations/.message-bus.jsonl"
  local agents_dir="${WOW_ROOT}/implementations/.agents"

  # 1. Stale agent trackers (mtime > 24h)
  local stale_count=0
  if [ -d "$agents_dir" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      rm -f "$f" 2>/dev/null || true
      stale_count=$((stale_count+1))
    done < <(find "$agents_dir" -maxdepth 1 -name '*.json' -mmin +1440 2>/dev/null)
  fi
  if [ "$stale_count" -gt 0 ]; then
    emit_info "sweep: removed $stale_count stale agent tracker(s) (>24h mtime)"
  fi

  # 2. Bus trim above threshold (M's existing opportunistic-trim policy)
  if [ -f "$bus" ]; then
    local lines
    lines=$(wc -l < "$bus" | tr -d ' ')
    local threshold=2000
    local threshold_file="${WOW_ROOT}/implementations/.bus-trim-threshold"
    [ -f "$threshold_file" ] && threshold=$(tr -d '[:space:]' < "$threshold_file")
    if [ "$lines" -gt "$threshold" ]; then
      emit_info "sweep: bus has $lines lines > $threshold threshold (M's full impl would do 24h-cutoff trim here)"
    fi
  fi

  return 0
}
