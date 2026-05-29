#!/usr/bin/env bash
# Story 155 — drive the 5 transitions in sequence; each transition emits
# a `reactions.remove` + `reactions.add` pair (except the very first, which
# is add-only since there's no prior emoji).

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

[ -f "$BRIDGE/dist/bridge/reactions.js" ] || (cd "$BRIDGE" && npm run build >/dev/null 2>&1)

TMPDIR_FX=$(mktemp -d)

node --input-type=module -e "
import { ReactionManager } from '$BRIDGE/dist/bridge/reactions.js';
const calls = [];
const fakeClient = {
  reactions: {
    add: async ({ name }) => { calls.push('add:' + name); return { ok: true }; },
    remove: async ({ name }) => { calls.push('remove:' + name); return { ok: true }; },
    get: async () => ({ message: { reactions: [] } }),
  },
};
const mgr = new ReactionManager(fakeClient);
await mgr.setState('C', 'T', 'received');
await mgr.setState('C', 'T', 'thinking');
await mgr.setState('C', 'T', 'done');
process.stdout.write(JSON.stringify(calls.filter(c => !c.startsWith('get'))));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

OPS=$(jq -r '. | join(",")' "$TMPDIR_FX/out.json")
EXPECTED="add:eyes,remove:eyes,add:thinking_face,remove:thinking_face,add:white_check_mark"
assert_eq "5-call sequence (received→thinking→done)" "$EXPECTED" "$OPS"

# Now drive the alternate paths: received → refusing; new ts received → escalated
node --input-type=module -e "
import { ReactionManager } from '$BRIDGE/dist/bridge/reactions.js';
const calls = [];
const fakeClient = {
  reactions: {
    add: async ({ name }) => { calls.push('add:' + name); return { ok: true }; },
    remove: async ({ name }) => { calls.push('remove:' + name); return { ok: true }; },
    get: async () => ({ message: { reactions: [] } }),
  },
};
const mgr = new ReactionManager(fakeClient);
await mgr.setState('C', 'T1', 'received');
await mgr.setState('C', 'T1', 'refusing');
await mgr.setState('C', 'T2', 'received');
await mgr.setState('C', 'T2', 'escalated');
process.stdout.write(JSON.stringify(calls.filter(c => !c.startsWith('get'))));
" > "$TMPDIR_FX/out2.json" 2>>"$TMPDIR_FX/err"

OPS2=$(jq -r '. | join(",")' "$TMPDIR_FX/out2.json")
EXPECTED2="add:eyes,remove:eyes,add:x,add:eyes,remove:eyes,add:rotating_light"
assert_eq "alternate-path sequence (received→refusing; received→escalated)" "$EXPECTED2" "$OPS2"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
