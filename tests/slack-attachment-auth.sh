#!/usr/bin/env bash
# Story 157 — download HTTPS GET MUST include Bearer auth header.

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
let captured = null;
const server = createServer((req, res) => { captured = req.headers['authorization'] ?? null; res.writeHead(200); res.end('x'); });
await new Promise(r => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
const att = new Attachments({ baseDir: '$BASE', botToken: 'xoxb-test-token' });
await att.downloadForMessage([{ id: 'F1', name: 'x.png', mimetype: 'image/png', size: 1, url_private_download: 'http://127.0.0.1:' + port + '/x' }], '1.2');
await new Promise(r => server.close(() => r()));
process.stdout.write(JSON.stringify({ auth: captured }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

AUTH=$(jq -r '.auth' "$TMPDIR_FX/out.json")
assert_eq "Authorization: Bearer xoxb-test-token" "Bearer xoxb-test-token" "$AUTH"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
