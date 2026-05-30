#!/usr/bin/env bash
# scripts/whats-my-role.sh — central role-identification primitive.
#
# Sourceable (functions wow_*) and CLI-invocable.
# Mechanism: PPID-walk to find claude session PID; marker file under
# .claude/.session-role-by-claude-pid/<pid> contains the role token.
#
# CLI:
#   bash scripts/whats-my-role.sh whats-my-role     -> echo role; exit 0/1
#   bash scripts/whats-my-role.sh claim <role>      -> write marker; exit 0/2
#   bash scripts/whats-my-role.sh release           -> rm marker; exit 0
#   bash scripts/whats-my-role.sh sweep             -> sweep stale; exit 0
#   bash scripts/whats-my-role.sh find-claude-pid   -> echo PID; exit 0/1

set -u

# Resolve the MAIN repo root (where .claude/ markers live). Reconciled idiom
# (stories 174 + 173): honor $WOW_ROOT first (test-fixture override — keeps a
# test's role markers out of the real repo's .claude/, story 174 marker-leak
# vector); otherwise resolve WORKTREE-INVARIANTLY via the shared --git-common-dir
# (story 173 — a linked worktree's --show-toplevel is the worktree root, whose
# .claude/ holds no markers, which silently broke the M-exemption). NEVER use
# --show-toplevel here.
if [ -n "${WOW_ROOT:-}" ]; then
  ROOT="$WOW_ROOT"
else
  ROOT=$(pwd)
  if _wow_gcd=$(git rev-parse --git-common-dir 2>/dev/null); then
    case "$_wow_gcd" in /*) ;; *) _wow_gcd="$(pwd)/$_wow_gcd" ;; esac
    ROOT=$(cd "$(dirname "$_wow_gcd")" 2>/dev/null && pwd) || ROOT=$(pwd)
  fi
  unset _wow_gcd
fi
MARKER_DIR="${ROOT}/.claude/.session-role-by-claude-pid"

# Lower-level: walk parent chain to find claude session PID. Echoes PID.
wow_find_claude_pid() {
  local pid=$$ depth=0 cmd binary ppid
  while [ "$pid" != "1" ] && [ -n "$pid" ] && [ "$depth" -lt 25 ]; do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    binary=$(echo "$cmd" | awk '{print $1}')
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Skip depth 0 (current bash subprocess); match binary basename only at depth >= 1
    if [ "$depth" -ge 1 ]; then
      case "$binary" in
        */claude|claude|*claude/cli*|*claude/*/cli*)
          echo "$pid"
          return 0
          ;;
      esac
    fi
    pid="$ppid"
    depth=$((depth+1))
  done
  return 1
}

# Lower-level: read marker file for given claude PID. Echoes role.
wow_read_role_by_claude_pid() {
  local pid="$1"
  local marker="${MARKER_DIR}/${pid}"
  [ -r "$marker" ] || return 1
  local role
  role=$(tr -d '[:space:]' < "$marker")
  case "$role" in
    manager|pair-programmer|senior-developer|tester|slacker)
      echo "$role"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Public: agent startup. Writes marker for current session.
# Args: <role>. Idempotent on same role; exit 2 on different-role conflict.
wow_claim_role() {
  local role="$1"
  local pid
  pid=$(wow_find_claude_pid) || { echo "wow_claim_role: cannot find claude PID" >&2; return 1; }
  mkdir -p "$MARKER_DIR"
  local marker="${MARKER_DIR}/${pid}"
  if [ -r "$marker" ]; then
    local existing
    existing=$(tr -d '[:space:]' < "$marker")
    if [ "$existing" = "$role" ]; then
      return 0
    fi
    echo "wow_claim_role: PID $pid already claimed as '$existing'; refusing to reclaim as '$role'" >&2
    return 2
  fi
  printf '%s\n' "$role" > "$marker"
  chmod 0644 "$marker" 2>/dev/null
  return 0
}

# Public: returns role of calling session.
wow_whats_my_role() {
  local pid
  pid=$(wow_find_claude_pid) || { echo "unknown" >&2; return 1; }
  wow_read_role_by_claude_pid "$pid"
}

# Public: agent exit ceremony. Removes marker for current session.
wow_release_role() {
  local pid
  pid=$(wow_find_claude_pid) || return 0
  rm -f "${MARKER_DIR}/${pid}" 2>/dev/null
  return 0
}

# Public: M Phase 1 sweep. Removes markers whose claude PID is no longer in ps.
wow_sweep_stale_role_markers() {
  [ -d "$MARKER_DIR" ] || return 0
  local marker pid
  for marker in "$MARKER_DIR"/*; do
    [ -f "$marker" ] || continue
    pid=$(basename "$marker")
    case "$pid" in
      ''|*[!0-9]*) rm -f "$marker"; continue ;;
    esac
    if ! ps -p "$pid" >/dev/null 2>&1; then
      rm -f "$marker"
    fi
  done
  return 0
}

# CLI dispatch (only when invoked directly, not when sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    whats-my-role) wow_whats_my_role ;;
    claim) wow_claim_role "${2:?usage: $0 claim <role>}" ;;
    release) wow_release_role ;;
    sweep) wow_sweep_stale_role_markers ;;
    find-claude-pid) wow_find_claude_pid ;;
    *) echo "usage: $0 {whats-my-role|claim <role>|release|sweep|find-claude-pid}" >&2; exit 1 ;;
  esac
fi
