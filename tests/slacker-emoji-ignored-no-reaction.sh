#!/usr/bin/env bash
# Story 155 — doctrine-grep: slacker.md establishes that ignored / filtered
# messages (own-bot, out-of-scope) get zero reactions. The bridge's
# eventIsFromOwnBot + inScope gates run BEFORE feed.append; S only calls
# /set-reaction after seeing a feed event. Since dropped events never appear,
# /set-reaction is never invoked for them. This test verifies the doctrine
# spells this out — the mechanical guarantee is in handlers.ts (covered by
# story 153's own-bot-filter tests).

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_grep() {
  local name="$1"; local pattern="$2"; local file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (pattern '$pattern' missing from $file)"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTRINE="$ROOT/commands/slacker.md"
HANDLERS="$ROOT/bridge/slack/src/bridge/handlers.ts"

assert_grep "doctrine mentions 'non-ignored'"      "non-ignored"      "$DOCTRINE"
assert_grep "handlers.ts has eventIsFromOwnBot gate" "eventIsFromOwnBot" "$HANDLERS"
assert_grep "handlers.ts has inScope gate"           "inScope\\("        "$HANDLERS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
