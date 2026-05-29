#!/usr/bin/env bash
# Story 156 — repeat visit within TTL: no users.info re-call,
# interaction_count bumps, first_seen preserved.

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

if [ ! -f "$BRIDGE/dist/bridge/interactors.js" ]; then
  (cd "$BRIDGE" && npm run build >/dev/null 2>&1) || { echo "build failed"; exit 1; }
fi

TMPDIR_FX=$(mktemp -d)
STORE="$TMPDIR_FX/interactors.json"

node --input-type=module -e "
import { Interactors } from '$BRIDGE/dist/bridge/interactors.js';
let calls = 0;
const fakeClient = { users: { info: async () => { calls++; return { user: { profile: { display_name: 'Alice', title: 'CTO' } } }; } } };
const reg = new Interactors({ path: '$STORE', ttlDays: 30 });
const r1 = await reg.ensureInteractor(fakeClient, 'U01');
await new Promise((r) => setTimeout(r, 50));
const r2 = await reg.ensureInteractor(fakeClient, 'U01');
process.stdout.write(JSON.stringify({ calls, firstSame: r1.first_seen === r2.first_seen, count2: r2.interaction_count }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

if [ ! -s "$TMPDIR_FX/out.json" ]; then
  cat "$TMPDIR_FX/err" >&2
  rm -rf "$TMPDIR_FX"; exit 1
fi

CALLS=$(jq -r '.calls' "$TMPDIR_FX/out.json")
SAME=$(jq -r '.firstSame' "$TMPDIR_FX/out.json")
COUNT=$(jq -r '.count2' "$TMPDIR_FX/out.json")

assert_eq "repeat: users.info called only once" "1" "$CALLS"
assert_eq "repeat: first_seen preserved" "true" "$SAME"
assert_eq "repeat: interaction_count bumped to 2" "2" "$COUNT"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
