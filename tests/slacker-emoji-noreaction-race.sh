#!/usr/bin/env bash
# Story 155 — Slack's reactions.remove returning `no_reaction` is non-blocking.
# The subsequent reactions.add MUST still fire + setState returns ok.

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
let addCount = 0;
const fakeClient = {
  reactions: {
    add: async () => { addCount++; return { ok: true }; },
    remove: async () => { const e = new Error('platform_error'); e.data = { error: 'no_reaction' }; throw e; },
    get: async () => ({ message: { reactions: [] } }),
  },
};
const mgr = new ReactionManager(fakeClient);
mgr._seedForTest('C', 'T', 'eyes');
const r = await mgr.setState('C', 'T', 'thinking');
process.stdout.write(JSON.stringify({ addCount, previous: r.previous, current: r.current }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

ADD=$(jq -r '.addCount' "$TMPDIR_FX/out.json")
PREV=$(jq -r '.previous' "$TMPDIR_FX/out.json")
CUR=$(jq -r '.current' "$TMPDIR_FX/out.json")

assert_eq "add still fired despite no_reaction on remove" "1" "$ADD"
assert_eq "previous=eyes" "eyes" "$PREV"
assert_eq "current=thinking_face" "thinking_face" "$CUR"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
