#!/usr/bin/env bash
# Story 156 — classifyTechnicality heuristic matrix.

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

node --input-type=module -e "
import { classifyTechnicality } from '$BRIDGE/dist/bridge/interactors.js';
const fixtures = [
  ['',                  false],
  [null,                false],
  ['Software Engineer', true],
  ['CTO',               true],
  ['Data Scientist',    true],
  ['Marketing Director', false],
  ['VP Sales',          false],
  ['Founder',           null],
  ['Founder & CTO',     true],
];
const out = fixtures.map(([t, expect]) => ({ title: t, expect, got: classifyTechnicality(t) }));
process.stdout.write(JSON.stringify(out));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

if [ ! -s "$TMPDIR_FX/out.json" ]; then
  cat "$TMPDIR_FX/err" >&2
  rm -rf "$TMPDIR_FX"; exit 1
fi

n=$(jq 'length' "$TMPDIR_FX/out.json")
for i in $(seq 0 $((n-1))); do
  TITLE=$(jq -r ".[$i].title // \"<null>\"" "$TMPDIR_FX/out.json")
  EXP=$(jq -r ".[$i].expect" "$TMPDIR_FX/out.json")
  GOT=$(jq -r ".[$i].got" "$TMPDIR_FX/out.json")
  assert_eq "classify['$TITLE']" "$EXP" "$GOT"
done

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
