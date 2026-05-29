#!/usr/bin/env bash
# Bug 0004 FINDING-45 regression guard. Malformed messageTs must not flow
# into any path construction; downloadForMessage returns [] and creates
# nothing outside baseDir.

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
BASE="$TMPDIR_FX/attachments"
mkdir -p "$BASE"
# Sibling dir to detect escape — if path traversal succeeded, the malicious
# write would land here.
SIBLING="$TMPDIR_FX/escaped"
mkdir -p "$SIBLING"

# Three adversarial inputs: classic ../, absolute escape, embedded slash.
node --input-type=module -e "
import { Attachments } from '$BRIDGE/dist/bridge/attachments.js';
const att = new Attachments({ baseDir: '$BASE', botToken: 't' });
const inputs = ['../../etc', '/etc', '1234.5678/../../etc', '1234567890', 'x.y'];
const results = [];
for (const ts of inputs) {
  const out = await att.downloadForMessage([{ id: 'F1', name: 'x.png', mimetype: 'image/png', size: 1, url_private_download: 'https://files.slack.com/x' }], ts);
  results.push({ ts, len: out.length });
}
process.stdout.write(JSON.stringify(results));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

n=$(jq 'length' "$TMPDIR_FX/out.json")
for i in $(seq 0 $((n-1))); do
  TS=$(jq -r ".[$i].ts" "$TMPDIR_FX/out.json")
  LEN=$(jq -r ".[$i].len" "$TMPDIR_FX/out.json")
  assert_eq "malformed messageTs '$TS' → returns []" "0" "$LEN"
done

# Belt-and-suspenders: ensure nothing was created outside baseDir
ESCAPED_FILES=$(find "$SIBLING" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no file created outside baseDir" "0" "$ESCAPED_FILES"

PARENT_FILES=$(find "$TMPDIR_FX" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
# only out.json + err allowed at top level
if [ "$PARENT_FILES" -le 2 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("unexpected files at $TMPDIR_FX top level (got $PARENT_FILES)"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
