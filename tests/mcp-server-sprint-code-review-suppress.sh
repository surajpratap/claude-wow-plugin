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

# NOTE (FINDING-36, Story 137): the suppression keys off the `base` field of the
# pr-created payload — the canonical producer key (every real emit + the doctrine in
# _agent-protocol.md / senior-developer.md). This test feeds `base` (the PRODUCER's
# real shape). It previously fed `pr_base` — the consumer's wrong key — which masked
# the inert suppression. Feeding `base` here is what makes it catch FINDING-36.

# (a) per-item PR + active sprint → suppressed (1 line, no code-review-request).
PA=$(mk_project "$ACTIVE")
emit_pr_created "$PA" '{"base":"sprint/x"}'
assert_eq "a-per-item-active-suppressed" "1" "$(lines "$PA")"
rm -rf "$PA"

# (b) inactive sprint whose integration_branch matches base → fires (2 lines).
# Proves status=="active" is genuinely required, not a bare integration_branch match.
PB=$(mk_project "$COMPLETE")
emit_pr_created "$PB" '{"base":"sprint/x"}'
assert_eq "b-inactive-sprint-fires" "2" "$(lines "$PB")"
assert_eq "b-line2-is-code-review-request" "code-review-request" \
  "$(sed -n '2p' "$PB/implementations/.message-bus.jsonl" | jq -r '.type // empty')"
rm -rf "$PB"

# (c) integration→main PR (base != integration_branch) + active sprint → fires.
PC=$(mk_project "$ACTIVE")
emit_pr_created "$PC" '{"base":"main"}'
assert_eq "c-integration-main-fires" "2" "$(lines "$PC")"
rm -rf "$PC"

# (d) no base in the payload + active sprint → fires (fail-safe).
PD=$(mk_project "$ACTIVE")
emit_pr_created "$PD" '{}'
assert_eq "d-no-base-fail-safe-fires" "2" "$(lines "$PD")"
rm -rf "$PD"

# (e) two active manifests + a matching base → fires (fail-safe — multiple
# active manifests is uncertainty; the helper returns None, so no suppression).
PE=$(mk_project "$ACTIVE")
mkdir -p "$PE/implementations/sprints/s2"
printf '%s\n' '{"status":"active","integration_branch":"sprint/y","items":[]}' \
  > "$PE/implementations/sprints/s2/manifest.json"
emit_pr_created "$PE" '{"base":"sprint/x"}'
assert_eq "e-two-active-manifests-fail-safe-fires" "2" "$(lines "$PE")"
rm -rf "$PE"

# (f) producer-shape assertion — pin all three corners on the `base` key so
# producer-side drift (the key has historically varied) is caught (FINDING-36,
# Added-AC #2). Both doctrine files carry the canonical marker phrase
# `suppression keys off `base`` so producer + protocol stay aligned with the
# consumer. grep -F (fixed-string) avoids regex trouble with backticks/parens.
SD_DOC="$ROOT/commands/senior-developer.md"
PROTO_DOC="$ROOT/commands/_agent-protocol.md"
SERVER_PY="$ROOT/mcp/claude-wow-server/server.py"
MARK='suppression keys off `base`'
# PRODUCER: SD's own role file documents the pr-created `base` key.
if grep -qF "$MARK" "$SD_DOC"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); FAILED_CASES+=("f-producer-doc-names-base (senior-developer.md missing '$MARK')"); fi
# DOCTRINE/PROTOCOL: the protocol spec documents the canonical suppression key.
if grep -qF "$MARK" "$PROTO_DOC"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); FAILED_CASES+=("f-protocol-doc-documents-base-key (_agent-protocol.md missing '$MARK')"); fi
# CONSUMER: server.py reads .get("base"), NOT .get("pr_base").
if grep -q 'pr_payload.get("base")' "$SERVER_PY" && ! grep -q 'pr_payload.get("pr_base")' "$SERVER_PY"; then
  PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); FAILED_CASES+=("f-consumer-reads-base-not-pr_base (server.py suppression block)"); fi

# Story 141 — reference adoption: the suppress contract's pr-created fixture
# validates against the golden set (would catch a future drift back to pr_base).
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")" && pwd)/lib/contract-golden.sh"
if assert_fixture_matches_golden pr-created '{"base":"sprint/x"}' 2>/dev/null; then
  PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("141-golden: pr-created fixture diverges from golden"); fi

echo "mcp-server-sprint-code-review-suppress: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
