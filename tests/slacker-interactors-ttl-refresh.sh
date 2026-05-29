#!/usr/bin/env bash
# Story 156 — past-TTL: users.info re-called; first_seen + interaction_count
# preserved across refresh; profile_fetched_at updated.

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
import { readFileSync, writeFileSync } from 'node:fs';
let calls = 0;
const fakeClient = { users: { info: async () => { calls++; return { user: { profile: { display_name: 'Alice', title: 'CTO' } } }; } } };
const reg1 = new Interactors({ path: '$STORE', ttlDays: 1 });
await reg1.ensureInteractor(fakeClient, 'U01');
const disk = JSON.parse(readFileSync('$STORE', 'utf8'));
disk.interactors.U01.profile_fetched_at = '2000-01-01T00:00:00Z';
disk.interactors.U01.first_seen = '2000-01-01T00:00:00Z';
writeFileSync('$STORE', JSON.stringify(disk));
const reg2 = new Interactors({ path: '$STORE', ttlDays: 1 });
const r2 = await reg2.ensureInteractor(fakeClient, 'U01');
process.stdout.write(JSON.stringify({ calls, firstSeen: r2.first_seen, refreshed: r2.profile_fetched_at !== '2000-01-01T00:00:00Z' }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

CALLS=$(jq -r '.calls' "$TMPDIR_FX/out.json")
FIRST=$(jq -r '.firstSeen' "$TMPDIR_FX/out.json")
REFRESHED=$(jq -r '.refreshed' "$TMPDIR_FX/out.json")

assert_eq "ttl-refresh: users.info re-called (2 total)" "2" "$CALLS"
assert_eq "ttl-refresh: first_seen preserved" "2000-01-01T00:00:00Z" "$FIRST"
assert_eq "ttl-refresh: profile_fetched_at updated" "true" "$REFRESHED"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
