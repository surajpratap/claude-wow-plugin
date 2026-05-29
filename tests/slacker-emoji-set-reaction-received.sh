#!/usr/bin/env bash
# Story 155 — Node-level smoke test: instantiating ReactionManager + calling
# setState('received') against a fake WebClient produces a single
# `reactions.add eyes` call + the expected response shape. The full bridge-
# endpoint integration is covered by the unit suite + manual / npm test;
# this bash test asserts the bash-callable end-to-end contract via a Node
# oneliner against the built dist.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE="$ROOT/bridge/slack"

if [ ! -f "$BRIDGE/dist/bridge/reactions.js" ]; then
  (cd "$BRIDGE" && npm run build >/dev/null 2>&1) || { echo "build failed"; exit 1; }
fi

TMPDIR_FX=$(mktemp -d)

node --input-type=module -e "
import { ReactionManager } from '$BRIDGE/dist/bridge/reactions.js';
const calls = [];
const fakeClient = {
  reactions: {
    add: async ({ name }) => { calls.push({op: 'add', name}); return { ok: true }; },
    remove: async ({ name }) => { calls.push({op: 'remove', name}); return { ok: true }; },
    get: async () => { calls.push({op: 'get'}); return { message: { reactions: [] } }; },
  },
};
const mgr = new ReactionManager(fakeClient);
const r = await mgr.setState('C01', 'T123', 'received');
process.stdout.write(JSON.stringify({ ops: calls, previous: r.previous, current: r.current }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

if [ ! -s "$TMPDIR_FX/out.json" ]; then
  cat "$TMPDIR_FX/err" >&2
  rm -rf "$TMPDIR_FX"; exit 1
fi

PREVIOUS=$(jq -r '.previous' "$TMPDIR_FX/out.json")
CURRENT=$(jq -r '.current' "$TMPDIR_FX/out.json")
ADD_CALLS=$(jq -r '[.ops[] | select(.op=="add") | .name] | length' "$TMPDIR_FX/out.json")
ADD_NAME=$(jq -r '[.ops[] | select(.op=="add") | .name][0]' "$TMPDIR_FX/out.json")

assert_eq "previous=null on first call" "null" "$PREVIOUS"
assert_eq "current=eyes" "eyes" "$CURRENT"
assert_eq "exactly one reactions.add call" "1" "$ADD_CALLS"
assert_eq "reactions.add called with 'eyes'" "eyes" "$ADD_NAME"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
