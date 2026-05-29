#!/usr/bin/env bash
# Story 157 — cleanup removes files past retention; recent files retained;
# empty <message_ts> dirs pruned.

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
mkdir -p "$BASE/1000.0" "$BASE/2000.0"
echo "old" > "$BASE/1000.0/0001-old.png"
echo "new" > "$BASE/2000.0/0001-new.png"
# Backdate the old file 30 days
PAST=$(($(date +%s) - 30 * 86400))
touch -t "$(date -r $PAST '+%Y%m%d%H%M.%S')" "$BASE/1000.0/0001-old.png"

node --input-type=module -e "
import { Attachments } from '$BRIDGE/dist/bridge/attachments.js';
const att = new Attachments({ baseDir: '$BASE', botToken: 't', retentionDays: 7 });
await att.cleanup();
" 2>"$TMPDIR_FX/err"

[ -f "$BASE/1000.0/0001-old.png" ] && { FAIL=$((FAIL+1)); FAILED_CASES+=("old file should be deleted"); } || PASS=$((PASS+1))
[ -f "$BASE/2000.0/0001-new.png" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("recent file should be retained"); }
[ -d "$BASE/1000.0" ] && { FAIL=$((FAIL+1)); FAILED_CASES+=("empty old dir should be pruned"); } || PASS=$((PASS+1))
[ -d "$BASE/2000.0" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("dir with recent file should remain"); }

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
