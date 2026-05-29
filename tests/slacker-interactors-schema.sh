#!/usr/bin/env bash
# Story 156 — interactor record schema contract.
# Asserts plugin/bridge/slack/src/bridge/interactors.ts declares every
# required field on InteractorRecord + that persist() writes mode 0600.
# Full record-shape behavior is exercised by the node:test unit suite
# (plugin/bridge/slack/tests/interactors.test.ts, run via `npm test`).

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_grep() {
  local name="$1"; local pattern="$2"; local file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (pattern '$pattern' missing from $file)"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOD="$ROOT/bridge/slack/src/bridge/interactors.ts"

assert_grep "user_id field"           "user_id:[[:space:]]*string"          "$MOD"
assert_grep "name field"              "name:[[:space:]]*string"             "$MOD"
assert_grep "title field"             "title:[[:space:]]*string"            "$MOD"
assert_grep "email field"             "email:[[:space:]]*string"            "$MOD"
assert_grep "role field"              "role:[[:space:]]*string"             "$MOD"
assert_grep "technical field"         "technical:[[:space:]]*boolean"       "$MOD"
assert_grep "first_seen field"        "first_seen:[[:space:]]*string"       "$MOD"
assert_grep "last_seen field"         "last_seen:[[:space:]]*string"        "$MOD"
assert_grep "interaction_count field" "interaction_count:[[:space:]]*number" "$MOD"
assert_grep "profile_fetched_at field" "profile_fetched_at:[[:space:]]*string" "$MOD"
assert_grep "override_source field"   "override_source:[[:space:]]*string"  "$MOD"
assert_grep "persist mode 0600"       "mode:[[:space:]]*0o600"              "$MOD"
assert_grep "persist parent mode 0700" "mode:[[:space:]]*0o700"             "$MOD"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
