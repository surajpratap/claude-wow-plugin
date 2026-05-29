#!/usr/bin/env bash
# Story 156 — first-contact behavior of Interactors registry.
# Exercises the COMPILED Interactors via a Node oneliner: first
# ensureInteractor call → users.info fetched once → record persisted
# with mode 0600. The unit suite covers richer behavior; this test
# proves the bash-side contract: invoking node on the built dist
# produces the expected disk state.

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
  echo "[slacker-interactors-first-contact] dist absent — running npm build" >&2
  (cd "$BRIDGE" && npm run build >/dev/null 2>&1) || { echo "build failed"; exit 1; }
fi

TMPDIR_FX=$(mktemp -d)
STORE="$TMPDIR_FX/interactors.json"

node --input-type=module -e "
import { Interactors } from '$BRIDGE/dist/bridge/interactors.js';
const fakeClient = { users: { info: async () => ({ user: { profile: { display_name: 'Alice', title: 'CTO', email: 'a@x.com' } } }) } };
const reg = new Interactors({ path: '$STORE' });
const rec = await reg.ensureInteractor(fakeClient, 'U01');
process.stdout.write(JSON.stringify({ name: rec.name, title: rec.title, email: rec.email, technical: rec.technical, count: rec.interaction_count }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

if [ ! -s "$TMPDIR_FX/out.json" ]; then
  echo "node oneliner produced no output"
  cat "$TMPDIR_FX/err" >&2
  rm -rf "$TMPDIR_FX"
  exit 1
fi

NAME=$(jq -r '.name' "$TMPDIR_FX/out.json")
TITLE=$(jq -r '.title' "$TMPDIR_FX/out.json")
EMAIL=$(jq -r '.email' "$TMPDIR_FX/out.json")
TECH=$(jq -r '.technical' "$TMPDIR_FX/out.json")
COUNT=$(jq -r '.count' "$TMPDIR_FX/out.json")

assert_eq "first-contact: name from profile" "Alice"   "$NAME"
assert_eq "first-contact: title from profile" "CTO"    "$TITLE"
assert_eq "first-contact: email from profile" "a@x.com" "$EMAIL"
assert_eq "first-contact: technical (CTO → true)" "true" "$TECH"
assert_eq "first-contact: interaction_count=1" "1" "$COUNT"

# Disk persistence: file exists + mode 600 (permission bits only)
if [ ! -f "$STORE" ]; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("disk store not created at $STORE")
else
  if MODE=$(stat -f '%Lp' "$STORE" 2>/dev/null); then :; else MODE=$(stat -c '%a' "$STORE"); fi
  assert_eq "disk store mode 600" "600" "$MODE"
fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
