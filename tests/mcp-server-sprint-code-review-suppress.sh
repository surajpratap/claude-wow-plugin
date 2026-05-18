#!/usr/bin/env bash
# Story 103 — the MCP server suppresses the per-item code-review auto-inject for
# a per-item PR into an active sprint's integration branch (Decision B). Every
# pr-created here passes `payload` as a JSON STRING — the production bus shape.

set -u
unset WOW_SPRINT_MANIFEST 2>/dev/null || true

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"
SENDER="senior-developer-20260518T070000-aabbcc"

if [ ! -f "$MCP_CALL" ]; then
  echo "mcp-server-sprint-code-review-suppress: SKIP — $MCP_CALL not found"
  exit 0
fi

# mk_project [<manifest-json>] — project dir; optional manifest at sprints/s1/.
mk_project() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  if [ -n "${1:-}" ]; then
    mkdir -p "$d/implementations/sprints/s1"
    printf '%s\n' "$1" > "$d/implementations/sprints/s1/manifest.json"
  fi
  echo "$d"
}

# emit_pr_created <project-dir> <payload-json> — bus_emit a pr-created whose
# `payload` field is a JSON STRING (the production bus shape).
emit_pr_created() {
  local d="$1" payload_str="$2" args
  args=$(jq -nc --arg from "$SENDER" --arg pl "$payload_str" \
    '{from:$from, type:"pr-created", to:"manager-*", payload:$pl}')
  CLAUDE_PROJECT_DIR="$d" bash "$MCP_CALL" bus_emit "$args" >/dev/null
}

lines() { wc -l < "$1/implementations/.message-bus.jsonl" | tr -d ' '; }

ACTIVE='{"status":"active","integration_branch":"sprint/x","items":[]}'
COMPLETE='{"status":"complete","integration_branch":"sprint/x","items":[]}'

# (a) per-item PR + active sprint → suppressed (1 line, no code-review-request).
PA=$(mk_project "$ACTIVE")
emit_pr_created "$PA" '{"pr_base":"sprint/x"}'
assert_eq "a-per-item-active-suppressed" "1" "$(lines "$PA")"
rm -rf "$PA"

# (b) inactive sprint whose integration_branch matches pr_base → fires (2 lines).
# Proves status=="active" is genuinely required, not a bare integration_branch match.
PB=$(mk_project "$COMPLETE")
emit_pr_created "$PB" '{"pr_base":"sprint/x"}'
assert_eq "b-inactive-sprint-fires" "2" "$(lines "$PB")"
assert_eq "b-line2-is-code-review-request" "code-review-request" \
  "$(sed -n '2p' "$PB/implementations/.message-bus.jsonl" | jq -r '.type // empty')"
rm -rf "$PB"

# (c) integration→main PR (pr_base != integration_branch) + active sprint → fires.
PC=$(mk_project "$ACTIVE")
emit_pr_created "$PC" '{"pr_base":"main"}'
assert_eq "c-integration-main-fires" "2" "$(lines "$PC")"
rm -rf "$PC"

# (d) no pr_base in the payload + active sprint → fires (fail-safe).
PD=$(mk_project "$ACTIVE")
emit_pr_created "$PD" '{}'
assert_eq "d-no-pr_base-fail-safe-fires" "2" "$(lines "$PD")"
rm -rf "$PD"

# (e) two active manifests + a matching pr_base → fires (fail-safe — multiple
# active manifests is uncertainty; the helper returns None, so no suppression).
PE=$(mk_project "$ACTIVE")
mkdir -p "$PE/implementations/sprints/s2"
printf '%s\n' '{"status":"active","integration_branch":"sprint/y","items":[]}' \
  > "$PE/implementations/sprints/s2/manifest.json"
emit_pr_created "$PE" '{"pr_base":"sprint/x"}'
assert_eq "e-two-active-manifests-fail-safe-fires" "2" "$(lines "$PE")"
rm -rf "$PE"

echo "mcp-server-sprint-code-review-suppress: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
