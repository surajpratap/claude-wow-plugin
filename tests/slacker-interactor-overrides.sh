#!/usr/bin/env bash
# Story 156 — override block in learnings/slacker.md wins over fresh users.info data.

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

if [ ! -f "$BRIDGE/dist/bridge/interactors.js" ]; then
  (cd "$BRIDGE" && npm run build >/dev/null 2>&1) || { echo "build failed"; exit 1; }
fi

TMPDIR_FX=$(mktemp -d)
STORE="$TMPDIR_FX/interactors.json"
OVR="$TMPDIR_FX/learnings.md"

cat > "$OVR" <<'EOF'
<!-- interactor-overrides -->
U01:
  technical: false
  role: stakeholder
<!-- /interactor-overrides -->
EOF

node --input-type=module -e "
import { Interactors } from '$BRIDGE/dist/bridge/interactors.js';
const fakeClient = { users: { info: async () => ({ user: { profile: { display_name: 'Alice', title: 'Senior Engineer' } } }) } };
const reg = new Interactors({ path: '$STORE', overridesPath: '$OVR' });
const rec = await reg.ensureInteractor(fakeClient, 'U01');
process.stdout.write(JSON.stringify({ tech: rec.technical, role: rec.role, src: rec.override_source }));
" > "$TMPDIR_FX/out.json" 2>"$TMPDIR_FX/err"

TECH=$(jq -r '.tech' "$TMPDIR_FX/out.json")
ROLE=$(jq -r '.role' "$TMPDIR_FX/out.json")
SRC=$(jq -r '.src' "$TMPDIR_FX/out.json")

assert_eq "override: technical (false wins over title=Senior Engineer→true)" "false" "$TECH"
assert_eq "override: role added" "stakeholder" "$ROLE"
assert_eq "override: override_source flagged" "learnings" "$SRC"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
