#!/usr/bin/env bash
# Story 157 — `<!-- attachment-mimes -->` block in WOW_SLACK_ATTACHMENT_OVERRIDES_PATH
# REPLACES the default lists (not merged).

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
OVR="$TMPDIR_FX/learnings.md"

cat > "$OVR" <<'EOF'
<!-- attachment-mimes -->
allow:
  - text/*
block:
  - exe
<!-- /attachment-mimes -->
EOF

node --input-type=module -e "
import { Attachments } from '$BRIDGE/dist/bridge/attachments.js';
const att = new Attachments({ baseDir: '$BASE', botToken: 't', overridesPath: '$OVR' });
const out = await att.downloadForMessage([
  { id: 'F1', name: 'x.png', mimetype: 'image/png', size: 1, url_private_download: 'http://unused' },
], '1.2');
process.stdout.write(JSON.stringify(out[0]));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

SKIP=$(jq -r '.skipped' "$TMPDIR_FX/out.json")
REASON=$(jq -r '.skip_reason' "$TMPDIR_FX/out.json")

assert_eq "image/png skipped (no longer in override allow)" "true" "$SKIP"
if [[ "$REASON" == *"not allowed"* ]]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("skip_reason missing 'not allowed' (got '$REASON')"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
