#!/usr/bin/env bash
# Story 155 — assert the default catalogue in reactions.ts matches the
# 5-row markdown table in commands/slacker.md's `# Emoji state machine`
# section. Drift between code and doctrine is a real bug (S sends a state
# the bridge doesn't know about).

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTRINE="$ROOT/commands/slacker.md"
SRC="$ROOT/bridge/slack/src/bridge/reactions.ts"

# Extract catalogue from reactions.ts (matches `<state>: '<emoji>',`).
code_pairs=$(grep -oE "^[[:space:]]+(received|thinking|done|refusing|escalated):[[:space:]]+'[a-z_]+'" "$SRC" \
  | sed -E "s/^[[:space:]]+([a-z_]+):[[:space:]]+'([a-z_]+)'/\1=\2/" \
  | sort)

# Extract from doctrine (rows like `| \`received\` | 👀 | \`eyes\` | ...`).
# Pin to the table structure: state column, emoji column (non-|), name column.
doctrine_pairs=$(grep -E "^\| \`(received|thinking|done|refusing|escalated)\`" "$DOCTRINE" \
  | sed -E "s/^\| \`([a-z_]+)\` \| [^|]+ \| \`([a-z_]+)\` \|.*/\1=\2/" \
  | sort)

assert_eq "5 states in code" "5" "$(echo "$code_pairs" | wc -l | tr -d ' ')"
assert_eq "5 states in doctrine" "5" "$(echo "$doctrine_pairs" | wc -l | tr -d ' ')"

if [ "$code_pairs" = "$doctrine_pairs" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("catalogue drift: code vs doctrine differ — code='$code_pairs' doctrine='$doctrine_pairs'")
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
