#!/usr/bin/env bash
# Story 152 — phase_layout.
# mkdir -p the implementations/ skeleton + touch .message-bus.jsonl,
# .review.txt. M-only in the parameterization matrix.

phase_layout() {
  local role="$1"
  local impl="${WOW_ROOT}/implementations"
  mkdir -p "$impl/plans" "$impl/stories" "$impl/backlog" "$impl/agents" \
    "$impl/learnings" "$impl/tests-stories" "$impl/bugs" "$impl/sprints" \
    "$impl/.agents" "$impl/.wow-process"
  touch "$impl/.message-bus.jsonl" "$impl/.review.txt"
  emit_info "layout: implementations/ skeleton ensured"
  return 0
}
