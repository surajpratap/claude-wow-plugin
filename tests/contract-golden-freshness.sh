#!/usr/bin/env bash
# contract-golden-freshness.sh — Story 141 anti-drift guard.
#
# Asserts each golden in tests/fixtures/golden/ still matches its REAL producer
# (so a golden can't silently rot away from the contract it pins), AND that the
# `assert_fixture_matches_golden` helper FAILS on the committed wrong-shape
# fixtures (red-green: proves the guard catches FINDING-36/37/32 at author time).
#
# bus-message: invoke the real bus_emit in a TEMP PROJECT (never the repo bus).
# manifest-item: diff against a real in-repo sprint manifest item.
# pr-created: doc-anchor (the producer isn't in-test-invocable) — assert the
#   golden's `base` key matches the canonical key documented in the protocol +
#   SD doctrine; also diff against a real pr-created bus line when one exists.

set -u
PASS=0; FAIL=0; FAILED=()
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); FAILED+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
GOLDEN="$PLUGIN_ROOT/tests/fixtures/golden"
MCP_CALL="$PLUGIN_ROOT/tests/fixtures/mcp-call.sh"
# shellcheck source=/dev/null
. "$PLUGIN_ROOT/tests/lib/contract-golden.sh"

# shape signature (path:type, _provenance excluded) for a JSON value on stdin
sig(){ jq -r 'paths as $p | select($p[0] != "_provenance") | (($p|map(tostring))|join(".")) + ":" + (getpath($p)|type)' | LC_ALL=C sort -u; }
# is set A ($1) a subset of set B ($2)? (every line of A present in B)
is_subset(){ [ -z "$(comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2"))" ]; }

# ---- Arm 1: bus-message freshness — REAL bus_emit in a temp project ----------
if [ -f "$MCP_CALL" ]; then
  TMP=$(mktemp -d); mkdir -p "$TMP/implementations"
  CLAUDE_PROJECT_DIR="$TMP" bash "$MCP_CALL" bus_emit \
    '{"from":"senior-developer-20260101T000000-aabbcc","type":"pong","to":"manager-*","in_reply_to":"2026-01-01T00:00:00Z","payload":{"nonce":"fresh"}}' >/dev/null 2>&1
  REAL=$(tail -1 "$TMP/implementations/.message-bus.jsonl" 2>/dev/null)
  rm -rf "$TMP"
  GSIG=$(sig < "$GOLDEN/bus-message.json"); RSIG=$(printf '%s' "$REAL" | sig)
  if [ -n "$REAL" ] && is_subset "$GSIG" "$RSIG"; then ok; else
    bad "bus-message golden drifted from real bus_emit (golden paths not all in real emit)"; fi
  # the load-bearing FINDING-32 assertion: real emit wraps in_reply_to as an OBJECT
  if [ "$(printf '%s' "$REAL" | jq -r '.in_reply_to|type')" = "object" ]; then ok; else
    bad "real bus_emit in_reply_to is not an object (FINDING-32 regression)"; fi
else
  echo "contract-golden-freshness: SKIP bus-message arm — $MCP_CALL absent" >&2
fi

# ---- Arm 2: manifest-item freshness — diff vs a real in-repo manifest item ---
# glob (not ls|head) for shellcheck-clean + portable; any real manifest item has the shape we check
set -- "$REPO_ROOT"/implementations/sprints/*/manifest.json
REAL_MAN=""; for _m in "$@"; do [ -f "$_m" ] && REAL_MAN="$_m"; done  # last match = latest date
if [ -n "$REAL_MAN" ]; then
  RITEM=$(jq -c '.items[0]' "$REAL_MAN")
  # golden's id+story paths must exist in the real item; neither may carry story_id
  if printf '%s' "$RITEM" | jq -e 'has("id") and has("story")' >/dev/null 2>&1 \
     && jq -e 'has("id") and has("story")' "$GOLDEN/manifest-item.json" >/dev/null 2>&1; then ok; else
    bad "manifest-item golden/real missing id+story"; fi
  if ! jq -e 'has("story_id")' "$GOLDEN/manifest-item.json" >/dev/null 2>&1 \
     && ! printf '%s' "$RITEM" | jq -e 'has("story_id")' >/dev/null 2>&1; then ok; else
    bad "manifest-item carries story_id (FINDING-37 regression)"; fi
else
  echo "contract-golden-freshness: SKIP manifest-item arm — no sprint manifest" >&2
fi

# ---- Arm 3: pr-created doc-anchor (producer not in-test-invocable) -----------
if jq -e 'has("base") and (has("pr_base")|not)' "$GOLDEN/pr-created.json" >/dev/null 2>&1; then ok; else
  bad "pr-created golden missing base / has pr_base (FINDING-36 regression)"; fi
# the canonical suppression key is documented as `base` in the protocol doctrine
# shellcheck disable=SC2016  # literal backticks intentional (matching the doc's `base` code-span)
if grep -Eq 'suppression keys off `base`|`base`.*(suppress|integration_branch)|pr-created.*`base`' "$PLUGIN_ROOT/commands/_agent-protocol.md"; then ok; else
  bad "_agent-protocol.md does not document the canonical pr-created suppression key (base)"; fi

# ---- Arm 4: red-green — the helper MUST fail on the committed bad fixtures ---
for badf in "$GOLDEN"/bad/*.json; do
  [ -e "$badf" ] || continue
  name=$(basename "$badf"); golden_name="${name%%-*}"
  case "$name" in
    pr-created-*)    gn="pr-created" ;;
    manifest-item-*) gn="manifest-item" ;;
    bus-message-*)   gn="bus-message" ;;
    *) gn="$golden_name" ;;
  esac
  if assert_fixture_matches_golden "$gn" "$(jq -c 'del(._provenance)' "$badf")" >/dev/null 2>&1; then
    bad "helper PASSED a known-bad fixture: $name (red-green broken)"
  else ok; fi
done

echo "contract-golden-freshness: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
