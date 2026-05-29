#!/usr/bin/env bash
# Story 155 — synthetic learnings/slacker.md with `<!-- emoji-overrides -->`
# block changes the resolved catalogue. setState('done') resolves to the
# overridden emoji, not the default.

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

[ -f "$BRIDGE/dist/bridge/reactions.js" ] || (cd "$BRIDGE" && npm run build >/dev/null 2>&1)

TMPDIR_FX=$(mktemp -d)
OVR="$TMPDIR_FX/learnings.md"

cat > "$OVR" <<'EOF'
<!-- emoji-overrides -->
done=tada
received=eyes_open
<!-- /emoji-overrides -->
EOF

node --input-type=module -e "
import { ReactionManager } from '$BRIDGE/dist/bridge/reactions.js';
const calls = [];
const fakeClient = {
  reactions: {
    add: async ({ name }) => { calls.push(name); return { ok: true }; },
    remove: async () => { return { ok: true }; },
    get: async () => ({ message: { reactions: [] } }),
  },
};
const mgr = new ReactionManager(fakeClient, '$OVR');
const r1 = await mgr.setState('C', 'T', 'received');
const r2 = await mgr.setState('C', 'T', 'done');
process.stdout.write(JSON.stringify({ r1: r1.current, r2: r2.current, calls }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

R1=$(jq -r '.r1' "$TMPDIR_FX/out.json")
R2=$(jq -r '.r2' "$TMPDIR_FX/out.json")

assert_eq "override: received=eyes_open" "eyes_open" "$R1"
assert_eq "override: done=tada"          "tada"      "$R2"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
