#!/usr/bin/env bash
# Story 157 — blocked filetype skipped; allowed mime downloaded; mixed-message test.

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

node --input-type=module -e "
import { createServer } from 'node:http';
import { Attachments } from '$BRIDGE/dist/bridge/attachments.js';
const server = createServer((_, res) => { res.writeHead(200); res.end('img'); });
await new Promise(r => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
const url = 'http://127.0.0.1:' + port + '/x';
const att = new Attachments({ baseDir: '$BASE', botToken: 't' });
const out = await att.downloadForMessage([
  { id: 'F1', name: 'mal.exe', filetype: 'exe', mimetype: 'application/octet-stream', size: 1, url_private_download: url },
  { id: 'F2', name: 'pic.png', mimetype: 'image/png', size: 3, url_private_download: url },
], '1.2');
await new Promise(r => server.close(() => r()));
process.stdout.write(JSON.stringify(out));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

SKIP0=$(jq -r '.[0].skipped' "$TMPDIR_FX/out.json")
SKIP_REASON0=$(jq -r '.[0].skip_reason' "$TMPDIR_FX/out.json")
SKIP1=$(jq -r '.[1].skipped // false' "$TMPDIR_FX/out.json")
PATH1=$(jq -r '.[1].path' "$TMPDIR_FX/out.json")

assert_eq "exe skipped" "true" "$SKIP0"
if [[ "$SKIP_REASON0" == *"filetype blocked"* ]]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("exe skip_reason missing 'filetype blocked' (got '$SKIP_REASON0')"); fi
assert_eq "image/png NOT skipped" "false" "$SKIP1"
if [ -f "$PATH1" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("image/png file not written at $PATH1"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
