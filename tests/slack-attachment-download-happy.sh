#!/usr/bin/env bash
# Story 157 — happy path via Node oneliner against the built dist:
# instantiate Attachments + downloadForMessage with a fixture file →
# disk write produces correctly-named path under <message_ts>/, returned
# enriched record carries path + mime + original_filename + slack_file_id.

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
const server = createServer((_, res) => { res.writeHead(200, {'content-type': 'image/png'}); res.end(Buffer.from('PNG-FIXTURE')); });
await new Promise(r => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
const att = new Attachments({ baseDir: '$BASE', botToken: 'xoxb-test', _allowedHostSuffixesForTest: ['files.slack.com', '.slack.com', '127.0.0.1'] });
const out = await att.downloadForMessage([{ id: 'F1', name: 'screenshot.png', mimetype: 'image/png', size: 11, url_private_download: 'http://127.0.0.1:' + port + '/x' }], '1234.5678');
await new Promise(r => server.close(() => r()));
process.stdout.write(JSON.stringify(out[0]));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

if [ ! -s "$TMPDIR_FX/out.json" ]; then
  cat "$TMPDIR_FX/err" >&2
  rm -rf "$TMPDIR_FX"; exit 1
fi

MIME=$(jq -r '.mime' "$TMPDIR_FX/out.json")
NAME=$(jq -r '.original_filename' "$TMPDIR_FX/out.json")
ID=$(jq -r '.slack_file_id' "$TMPDIR_FX/out.json")
P=$(jq -r '.path' "$TMPDIR_FX/out.json")

assert_eq "mime preserved" "image/png" "$MIME"
assert_eq "original_filename preserved" "screenshot.png" "$NAME"
assert_eq "slack_file_id preserved" "F1" "$ID"
if [[ "$P" == */1234.5678/0001-screenshot.png ]]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("path layout (got '$P')"); fi

if [ -f "$P" ]; then
  CONTENT=$(cat "$P")
  assert_eq "file content" "PNG-FIXTURE" "$CONTENT"
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("downloaded file does not exist at $P")
fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
