#!/usr/bin/env bash
# Story 157 — two files with the same original_filename in one message
# get distinct on-disk names via the 0001/0002 counter prefix.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE="$ROOT/bridge/slack"
[ -f "$BRIDGE/dist/bridge/attachments.js" ] || (cd "$BRIDGE" && npm run build >/dev/null 2>&1)

TMPDIR_FX=$(mktemp -d)
BASE="$TMPDIR_FX/attachments"

node --input-type=module -e "
import { createServer } from 'node:http';
import { Attachments } from '$BRIDGE/dist/bridge/attachments.js';
const server = createServer((_, res) => { res.writeHead(200); res.end('x'); });
await new Promise(r => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
const url = 'http://127.0.0.1:' + port + '/x';
const att = new Attachments({ baseDir: '$BASE', botToken: 't' });
const out = await att.downloadForMessage([
  { id: 'F1', name: 'screenshot.png', mimetype: 'image/png', size: 1, url_private_download: url },
  { id: 'F2', name: 'screenshot.png', mimetype: 'image/png', size: 1, url_private_download: url },
], '1.2');
await new Promise(r => server.close(() => r()));
process.stdout.write(JSON.stringify(out));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

P1=$(jq -r '.[0].path' "$TMPDIR_FX/out.json")
P2=$(jq -r '.[1].path' "$TMPDIR_FX/out.json")

if [[ "$P1" == */0001-screenshot.png && "$P2" == */0002-screenshot.png ]]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("counter prefixes wrong (got '$P1' + '$P2')")
fi
[ -f "$P1" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("file 1 not on disk"); }
[ -f "$P2" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("file 2 not on disk"); }

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
