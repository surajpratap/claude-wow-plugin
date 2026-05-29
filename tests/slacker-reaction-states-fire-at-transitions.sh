#!/usr/bin/env bash
# Bug 0008 (HIGH) — BEHAVIORAL test for Slacker reaction wiring:
#
#  1. slacker.md MANDATES `/set-reaction` for received / refusing /
#     escalated at the right decision-tree branches (imperative-grep,
#     not existence-grep).
#  2. ReactionManager.lazyReconcile() actually returns the bot's prior
#     reaction across restarts (pre-Story-163 always returned null even
#     when reactions existed; reactions stacked instead of replacing).
#
# Pre-Story-163, the 3 imperatives were missing AND lazyReconcile was a
# dead branch. The shape-only "the table mentions all 5 states" test
# passed. This test fails on either gap.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE="$ROOT/bridge/slack"
DOCTRINE="$ROOT/commands/slacker.md"

# ---- Case 1: doctrine imperatives for each missing state ----
# Distinguishes "the doctrine mentions state X" (table entry, prose
# reference) from "the doctrine MANDATES the call at a transition"
# (imperative line near the decision-tree section).

for state in received refusing escalated; do
  # Match an imperative pattern: "set-reaction" appearing near `state: "<state>"`
  # within a decision-tree section (## 2, 3, or 4).
  if grep -qE "set-reaction.*state.*[\"']?$state[\"']?" "$DOCTRINE"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("1-imperative-$state (no '/set-reaction state:$state' imperative in slacker.md)")
  fi
done

# ---- Case 2: lazyReconcile returns the bot's prior reaction ----
[ -f "$BRIDGE/dist/bridge/reactions.js" ] || (cd "$BRIDGE" && npm run build >/dev/null 2>&1)

TMPDIR_FX=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FX"' EXIT INT TERM

# Mock Slack: reactions.get returns one own-bot reaction.
# Use auth.test to give the bot the id 'UBOT' so lazyReconcile knows itself.
node --input-type=module > "$TMPDIR_FX/out.txt" 2> "$TMPDIR_FX/err.txt" <<EOF
import { ReactionManager } from '$BRIDGE/dist/bridge/reactions.js';
const calls = [];
const fakeClient = {
  auth: { test: async () => ({ ok: true, user_id: 'UBOT' }) },
  reactions: {
    add:    async ({ name }) => { calls.push('add:' + name);    return { ok: true }; },
    remove: async ({ name }) => { calls.push('remove:' + name); return { ok: true }; },
    get:    async () => ({
      ok: true,
      message: {
        reactions: [
          { name: 'eyes', users: ['UBOT', 'UALICE'] },
          { name: 'thumbsup', users: ['UALICE'] },
        ],
      },
    }),
  },
};
const mgr = new ReactionManager(fakeClient);
// Simulate a bridge restart: in-memory map empty; bot previously left
// 'eyes' on C/T. setState should find that via lazyReconcile, remove it,
// then add 'thinking_face'.
const result = await mgr.setState('C', 'T', 'thinking');
process.stdout.write(JSON.stringify({ result, calls }));
EOF

if [ ! -s "$TMPDIR_FX/out.txt" ]; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("2-lazyReconcile-test-runtime-error (stderr: $(cat "$TMPDIR_FX/err.txt" 2>/dev/null | head -3 | tr '\n' '|'))")
else
  PREVIOUS=$(jq -r .result.previous "$TMPDIR_FX/out.txt")
  CURRENT=$(jq -r .result.current "$TMPDIR_FX/out.txt")
  OPS=$(jq -r '.calls | join(",")' "$TMPDIR_FX/out.txt")

  if [ "$PREVIOUS" = "eyes" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("2-lazyReconcile-returns-bot-reaction (expected 'eyes', got '$PREVIOUS')")
  fi

  if [ "$CURRENT" = "thinking_face" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("2-lazyReconcile-add-current (expected 'thinking_face', got '$CURRENT')")
  fi

  if echo "$OPS" | grep -qF "remove:eyes" && echo "$OPS" | grep -qF "add:thinking_face"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("2-lazyReconcile-remove+add-sequence (got '$OPS')")
  fi
fi

# ---- Case 3: lazyReconcile returns null when bot left no prior reaction ----
node --input-type=module > "$TMPDIR_FX/out3.txt" 2> "$TMPDIR_FX/err3.txt" <<EOF
import { ReactionManager } from '$BRIDGE/dist/bridge/reactions.js';
const calls = [];
const fakeClient = {
  auth: { test: async () => ({ ok: true, user_id: 'UBOT' }) },
  reactions: {
    add:    async ({ name }) => { calls.push('add:' + name);    return { ok: true }; },
    remove: async ({ name }) => { calls.push('remove:' + name); return { ok: true }; },
    get:    async () => ({
      ok: true,
      message: {
        reactions: [{ name: 'eyes', users: ['UALICE'] }],
      },
    }),
  },
};
const mgr = new ReactionManager(fakeClient);
const result = await mgr.setState('C', 'T2', 'received');
process.stdout.write(JSON.stringify({ result, calls }));
EOF

if [ -s "$TMPDIR_FX/out3.txt" ]; then
  PREVIOUS3=$(jq -r .result.previous "$TMPDIR_FX/out3.txt")
  OPS3=$(jq -r '.calls | join(",")' "$TMPDIR_FX/out3.txt")
  if [ "$PREVIOUS3" = "null" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("3-lazyReconcile-no-bot-reaction (expected null previous, got '$PREVIOUS3')")
  fi
  # Should only add, not remove (no prior to remove).
  if [ "$OPS3" = "add:eyes" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("3-lazyReconcile-no-remove (expected only 'add:eyes', got '$OPS3')")
  fi
fi

echo "slacker-reaction-states-fire-at-transitions: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
