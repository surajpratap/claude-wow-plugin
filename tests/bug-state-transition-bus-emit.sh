#!/usr/bin/env bash
# Bug 0006 (P0) — BEHAVIORAL test for bug-state-transition.sh's bus emit.
#
# The pre-Story-163 version of this test was source-grep-only ("script
# contains the string `bus_emit`") and passed even with the SILENTLY INERT
# `--exec bus-emit` form that never wrote a line to the bus. M's
# adversarial completeness audit (workflow wa4oyzoof) flagged this exact
# class as why 0006 shipped.
#
# This rewrite creates real state (fixture WOW_ROOT + bus file + bug
# file), invokes the REAL transition, and asserts a real bus line lands
# with the right shape. Reverting the script to the inert form makes
# THIS test fail — the regression guarantee shape-only tests cannot give.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/bug-state-transition.sh"

# Fixture: temp WOW_ROOT, real plugin scripts via wow-locate, real server.py.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT INT TERM
mkdir -p "$TMPROOT/implementations/bugs"
: > "$TMPROOT/implementations/.message-bus.jsonl"

write_bug() {
  local id="$1" status="$2"
  cat > "$TMPROOT/implementations/bugs/$id-fixture.md" <<EOF
<!-- status: $status -->
<!-- id: $id -->
<!-- reporter: test-agent -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- severity: medium -->
<!-- priority: P2 -->
<!-- affected-story: 999 -->
<!-- affected-version: 0.0.0 -->
<!-- triaged-by: test-agent -->

# Bug $id — fixture

## Reproduction
fixture
EOF
}

assert_bus_line() {
  local name="$1" expected_type="$2" expected_bug_id="$3"
  local line
  line=$(grep -F "\"type\":\"$expected_type\"" "$TMPROOT/implementations/.message-bus.jsonl" | tail -1)
  if [ -z "$line" ]; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (no bus line with type '$expected_type' found)")
    return 1
  fi
  if ! echo "$line" | grep -qF "\"bug_id\":\"$expected_bug_id\""; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (bus line did not carry bug_id '$expected_bug_id')")
    return 1
  fi
  PASS=$((PASS+1))
}

# Case 1: triage → fixing emits bug-fixing.
write_bug 0091 triaged
WOW_ROOT="$TMPROOT" CLAUDE_PROJECT_DIR="$TMPROOT" bash "$SCRIPT" 0091 fixing --agent-id senior-developer-20260529T100000-abc123
assert_bus_line "1-bug-fixing-emitted" "bug-fixing" "0091"

# Case 2: fixing → fixed (requires --pr-url + --fixed-in) emits bug-fixed.
write_bug 0092 fixing
WOW_ROOT="$TMPROOT" CLAUDE_PROJECT_DIR="$TMPROOT" bash "$SCRIPT" 0092 fixed --agent-id senior-developer-20260529T100000-abc123 \
  --pr-url "https://example.com/pr/1" --fixed-in "9.9.9"
assert_bus_line "2-bug-fixed-emitted" "bug-fixed" "0092"

# Case 3: verified → closed emits bug-closed.
write_bug 0093 verified
WOW_ROOT="$TMPROOT" CLAUDE_PROJECT_DIR="$TMPROOT" bash "$SCRIPT" 0093 closed --agent-id senior-developer-20260529T100000-abc123
assert_bus_line "3-bug-closed-emitted" "bug-closed" "0093"

# Case 4: the script must NOT swallow CLI errors with `2>/dev/null` —
# verify the source no longer contains the swallow pattern around the
# emit. This is a complement to behavior: a fail-loud guarantee is
# checked at the source level because behavioral tests can only assert
# what fires, not what would silently drop.
if grep -q 'python3 "$MCP_SERVER" .* 2>/dev/null' "$SCRIPT"; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("4-no-stderr-swallow (script still hides bus_emit failures behind 2>/dev/null)")
else
  PASS=$((PASS+1))
fi

# Case 5: T's 163-followup — when invoked with CWD inside a subdir that
# itself has `.claude-plugin/plugin.json` (the bundled plugin/ shape
# matches WOW_ROOT/plugin/.claude-plugin/plugin.json), the MCP server's
# find_project_root walks up from CWD and stops at the FIRST ancestor
# with that marker. Pre-fix, the bus line landed at
# `<wow-root>/plugin/implementations/.message-bus.jsonl` (a fresh path
# the bridge created) — invisible to every other agent. Post-fix, the
# helper passes CLAUDE_PROJECT_DIR=$WOW_ROOT so the emit lands at
# `<wow-root>/implementations/.message-bus.jsonl` regardless of CWD.
TMPROOT2=$(mktemp -d)
mkdir -p "$TMPROOT2/implementations/bugs" "$TMPROOT2/plugin/.claude-plugin"
echo '{"name":"x","version":"0.0.0"}' > "$TMPROOT2/plugin/.claude-plugin/plugin.json"
cat > "$TMPROOT2/implementations/bugs/0094-fixture.md" <<EOF
<!-- status: triaged -->
<!-- id: 0094 -->
<!-- reporter: test-agent -->
EOF
# Invoke with CWD = $TMPROOT2/plugin (subdir with its own plugin marker).
( cd "$TMPROOT2/plugin" && WOW_ROOT="$TMPROOT2" bash "$SCRIPT" 0094 fixing \
  --agent-id senior-developer-20260529T100000-abc123 ) >/dev/null 2>&1

# Bus event MUST land at WOW_ROOT/implementations/, NOT the subdir.
ROOT_BUS="$TMPROOT2/implementations/.message-bus.jsonl"
SUB_BUS="$TMPROOT2/plugin/implementations/.message-bus.jsonl"
if [ -f "$ROOT_BUS" ] && grep -qF '"bug_id":"0094"' "$ROOT_BUS"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("5-cwd-subdir-still-routes-to-wow-root (bug event not in $ROOT_BUS)")
fi
if [ -f "$SUB_BUS" ]; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("5-subdir-bus-leaked (event landed at $SUB_BUS — should NOT exist)")
else
  PASS=$((PASS+1))
fi
rm -rf "$TMPROOT2"

echo ""
echo "bug-state-transition-bus-emit: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
