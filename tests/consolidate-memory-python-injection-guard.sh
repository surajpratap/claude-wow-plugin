#!/usr/bin/env bash
# Bug 0005 (HIGH code-injection in consolidate-memory.sh) regression guard.
#
# Before the fix, the script interpolated memory-file content (body, name)
# directly into python3 -c "..." source strings. A memory file containing
# ''' would have broken out of the triple-quoted body string and executed
# arbitrary python — the headline RCE vector the automated security review
# flagged on commit 6cae13e.
#
# This test plants a memory file with the breakout payload and asserts:
#   1. The script exits 0 (no python crash from injection).
#   2. The body lands in the learnings file VERBATIM (no execution).
#   3. No side-effect file from the would-be injection is created.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/consolidate-memory.sh"

TMPDIR_FX=$(mktemp -d)
ENCODED=$(echo "$TMPDIR_FX" | sed 's|/|-|g')
MEM="$TMPDIR_FX/.claude/projects/$ENCODED/memory"
mkdir -p "$MEM"

# Memory file whose body contains the triple-quote breakout pattern + a
# would-be RCE payload (writes a marker file outside baseDir if the
# vulnerable pre-fix code interprets it as python source).
SENTINEL="$TMPDIR_FX/RCE_FIRED"
cat > "$MEM/injection.md" <<EOF
---
name: injection-test
metadata:
  role: manager
---

This body contains ''' triple-quote breakout, then:
__import__('os').system('touch $SENTINEL')
and continues with ''' more text.
EOF

OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" manager 2>&1)
RC=$?

assert_eq "script exits 0" "0" "$RC"

# Most important: the RCE payload MUST NOT have run.
if [ -f "$SENTINEL" ]; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("CRITICAL: RCE sentinel was created — injection guard failed!")
else
  PASS=$((PASS+1))
fi

# The body should land in the learnings file verbatim (escapes treated as
# literal text, not python).
LEARNINGS="$TMPDIR_FX/implementations/learnings/manager.md"
if grep -q "triple-quote breakout" "$LEARNINGS" 2>/dev/null; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("body did not land in learnings file"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
