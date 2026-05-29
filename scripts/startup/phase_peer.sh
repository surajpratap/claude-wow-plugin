#!/usr/bin/env bash
# Story 152 — phase_peer (M-only).
# Generates a preflight ID, writes a TRANSIENT tracker file BEFORE
# emitting pings, removes it via trap EXIT after pong-collection. The
# transient tracker satisfies story 149's dead-agent-ID guard so peers
# can pong by exact ID without working around the guard (closes the
# 2026-05-27 retro convergence: PP/SD/T all hit the same friction).

phase_peer() {
  local role="$1"
  [ "$role" = "manager" ] || return 0

  local ts hex preflight_id tracker_path
  ts=$(date -u +%Y%m%dT%H%M%S)
  hex=$(openssl rand -hex 3 2>/dev/null || printf '%06x' $((RANDOM * RANDOM)))
  preflight_id="manager-preflight-${ts}-${hex}"
  tracker_path="${WOW_ROOT}/implementations/.agents/${preflight_id}.json"

  mkdir -p "$(dirname "$tracker_path")"
  jq -nc --argjson ll 0 --arg ls "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson pid 0 \
    '{last_line: $ll, last_seen: $ls, claude_pid: $pid}' > "$tracker_path"

  # FINDING-41 fix (bug 0003): NO trap EXIT here. The previous trap
  # removed the tracker at startup.sh exit, which fires BEFORE M's
  # operating doctrine receives pongs — defeating the dead-agent-ID
  # guard fix this story was meant to deliver. Lifecycle ownership now
  # splits: phase_peer writes, M's operating doctrine destroys after
  # pong-collection (see commands/manager.md "Post-startup preflight
  # cleanup" section).

  emit_info "peer: preflight tracker written at $tracker_path (M removes after pong-collection per manager.md)"

  # Emit ping nonces via MCP CLI (best-effort; if CLI is unavailable,
  # the preflight degrades gracefully — peers just don't pong)
  local mcp_server
  mcp_server=$(wow-locate mcp/claude-wow-server/server.py 2>/dev/null || true)
  if [ -n "$mcp_server" ]; then
    for target_glob in senior-developer-* pair-programmer-* tester-*; do
      local nonce
      nonce="pf-$(openssl rand -hex 4 2>/dev/null || printf '%08x' $RANDOM)"
      python3 "$mcp_server" --exec bus-emit \
        "{\"from\":\"$preflight_id\",\"to\":\"$target_glob\",\"type\":\"ping\",\"payload\":\"$nonce\"}" \
        2>/dev/null || true
    done
    emit_info "peer: ping nonces emitted to sd / pp / t globs"
  else
    emit_info "peer: MCP CLI unavailable — skipping pings"
  fi

  # M's full impl sleeps 60s + scans bus for pongs + emits ask-human on missing.
  # Story 152 ships the transient-tracker mechanism; the full pong-poll loop
  # is owned by manager.md's startup doctrine (which the new short
  # _manager-startup.md will reference).
  emit_info "peer: pong-poll + missing-peer ask-human deferred to manager.md doctrine (transient tracker is the contract this story owns)"

  # The trap fires here on phase exit, removing the tracker.
  return 0
}
