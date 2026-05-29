#!/usr/bin/env bash
# Bug 0004 FINDING-44 regression guard. Attacker-controlled non-Slack URL →
# bridge must NOT send the bot token to the wrong host. Skip + reason; no
# Authorization header observed on the mock server.

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

# Default (production) allowlist is in play — no test seam. The mock server
# pretends to be attacker.example. SSRF guard must reject before any header
# is sent.
node --input-type=module -e "
import { createServer } from 'node:http';
import { Attachments } from '$BRIDGE/dist/bridge/attachments.js';
let observedAuth = null;
let requestCount = 0;
const server = createServer((req, res) => {
  requestCount++;
  observedAuth = req.headers['authorization'] ?? null;
  res.writeHead(200);
  res.end('x');
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
const att = new Attachments({ baseDir: '$BASE', botToken: 'xoxb-test-token' });
const out = await att.downloadForMessage([{ id: 'F1', name: 'x.png', mimetype: 'image/png', size: 1, url_private_download: 'http://127.0.0.1:' + port + '/x' }], '1234.5678');
await new Promise(r => server.close(() => r()));
process.stdout.write(JSON.stringify({ skipped: out[0].skipped, reason: out[0].skip_reason, observedAuth, requestCount }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

SKIP=$(jq -r '.skipped' "$TMPDIR_FX/out.json")
REASON=$(jq -r '.reason' "$TMPDIR_FX/out.json")
AUTH=$(jq -r '.observedAuth' "$TMPDIR_FX/out.json")
REQS=$(jq -r '.requestCount' "$TMPDIR_FX/out.json")

assert_eq "skipped=true on non-Slack host" "true" "$SKIP"
if [[ "$REASON" == *"non-Slack host"* || "$REASON" == *"insecure scheme"* ]]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("skip_reason should mention non-Slack/insecure (got '$REASON')"); fi
assert_eq "Authorization header MUST NOT be sent" "null" "$AUTH"
assert_eq "no HTTP requests should reach the mock server" "0" "$REQS"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
