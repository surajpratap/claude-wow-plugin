#!/usr/bin/env bash
# Bug 0009 (MEDIUM) — BEHAVIORAL e2e test for the
# registerHandlers → enrichAttachments → feed wire.
#
# Pre-Story-163, all 10 `slack-attachment-*.sh` tests instantiated
# `Attachments` in isolation; none drove `registerHandlers` with an
# Attachments instance and asserted that a message event's enriched
# feed record carries `attachments:[{...}]`. The TS smoke test in
# `tests/bridge.smoke.test.ts` omits registerHandlers entirely. Shape
# was verified; wiring was untested.
#
# This test wires a mock Slack `App`, captures the registered message
# handler, fires an event with `files:[...]`, and asserts the feed
# `append` call received `attachments` carrying the download paths.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE="$ROOT/bridge/slack"

[ -f "$BRIDGE/dist/bridge/handlers.js" ] || (cd "$BRIDGE" && npm run build >/dev/null 2>&1)

TMPDIR_FX=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FX"' EXIT INT TERM
BASE="$TMPDIR_FX/attachments"
mkdir -p "$BASE"

node --input-type=module > "$TMPDIR_FX/out.txt" 2> "$TMPDIR_FX/err.txt" <<EOF
import { createServer } from 'node:http';
import { registerHandlers } from '$BRIDGE/dist/bridge/handlers.js';
import { Attachments }     from '$BRIDGE/dist/bridge/attachments.js';

const fileServer = createServer((_, res) => { res.writeHead(200); res.end('payload'); });
await new Promise(r => fileServer.listen(0, '127.0.0.1', r));
const port = fileServer.address().port;
const fileUrl = 'http://127.0.0.1:' + port + '/x';

const appended = [];
const feed = { append: async (rec) => { appended.push(rec); } };

const resolver = {
  channel: async () => ({ name: 'general', type: 'channel' }),
  user:    async () => ({ name: 'alice', tz: null, title: null }),
};

const identity = { botUserId: 'UBOT', botName: 'wow', teamId: 'T1' };
const interactors = null;
const scope = null;
const attachments = new Attachments({
  baseDir: '$BASE',
  botToken: 't',
  _allowedHostSuffixesForTest: ['127.0.0.1'],
});

// Mock Slack App: capture handler callbacks.
const handlers = {};
const app = {
  event:   (kind, fn) => { handlers[kind]    = fn; },
  message: (fn)       => { handlers.message  = fn; },
  error:   (fn)       => { handlers.error    = fn; },
};

registerHandlers({ app, feed, resolver, identity, scope, interactors, attachments });

// Fire a synthetic message event with one allowed-mime file.
await handlers.message({
  message: {
    type:    'message',
    ts:      '1.2',
    channel: 'C',
    user:    'UALICE',
    text:    'hello',
    files: [
      { id: 'F1', name: 'pic.png', mimetype: 'image/png', size: 7, url_private_download: fileUrl },
    ],
  },
});

await new Promise(r => fileServer.close(() => r()));
process.stdout.write(JSON.stringify({ appended }));
EOF

if [ ! -s "$TMPDIR_FX/out.txt" ]; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("0-runtime-error (stderr: $(head -5 "$TMPDIR_FX/err.txt" 2>/dev/null | tr '\n' '|'))")
else
  NUM_APPEND=$(jq -r '.appended | length' "$TMPDIR_FX/out.txt")
  if [ "$NUM_APPEND" = "1" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("1-feed-append-count (expected 1 record, got $NUM_APPEND)"); fi

  ATT_COUNT=$(jq -r '.appended[0].attachments | length' "$TMPDIR_FX/out.txt")
  if [ "$ATT_COUNT" = "1" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("2-attachments-count (expected 1, got $ATT_COUNT)"); fi

  ATT_PATH=$(jq -r '.appended[0].attachments[0].path // ""' "$TMPDIR_FX/out.txt")
  if [ -n "$ATT_PATH" ] && [ -f "$ATT_PATH" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("3-attachment-path-on-disk (path '$ATT_PATH' not found)"); fi
fi

echo "slack-attachments-handler-e2e: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
