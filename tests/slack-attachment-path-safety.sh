#!/usr/bin/env bash
# Story 157 — pathSafe sanitizes adversarial filenames.

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
[ -f "$BRIDGE/dist/bridge/attachments.js" ] || (cd "$BRIDGE" && npm run build >/dev/null 2>&1)

TMPDIR_FX=$(mktemp -d)

node --input-type=module -e "
import { pathSafe } from '$BRIDGE/dist/bridge/attachments.js';
const cases = [
  ['../../etc/passwd.png', '_etc_passwd.png'],
  ['a/b\\\\c:d.png', 'a_b_c_d.png'],
  ['', '_unnamed_'],
  ['normal.png', 'normal.png'],
];
process.stdout.write(JSON.stringify(cases.map(([input, expected]) => ({ input, expected, got: pathSafe(input) }))));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

n=$(jq 'length' "$TMPDIR_FX/out.json")
for i in $(seq 0 $((n-1))); do
  IN=$(jq -r ".[$i].input" "$TMPDIR_FX/out.json")
  EXP=$(jq -r ".[$i].expected" "$TMPDIR_FX/out.json")
  GOT=$(jq -r ".[$i].got" "$TMPDIR_FX/out.json")
  assert_eq "pathSafe('$IN')" "$EXP" "$GOT"
done

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
