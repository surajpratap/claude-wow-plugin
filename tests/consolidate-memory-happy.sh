#!/usr/bin/env bash
# Story 158 — happy path: single in-scope memory file → appended to
# role's learnings file with provenance footer + marked consolidated;
# summary JSON has entries_added=1.

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
cat > "$MEM/manager-test.md" <<'EOF'
---
name: a-manager-fact
description: A test fact
metadata:
  role: manager
---

A useful manager-specific fact about M's workflow.
EOF

OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" manager 2>&1)
ADDED=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('entries_added', -1))")
TRIAGE=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('triage_count', -1))")

assert_eq "entries_added=1" "1" "$ADDED"
assert_eq "triage_count=0" "0" "$TRIAGE"

LEARNINGS="$TMPDIR_FX/implementations/learnings/manager.md"
if grep -q "### a-manager-fact" "$LEARNINGS" 2>/dev/null; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("learnings file missing entry H3 heading"); fi
if grep -q "consolidated from memory: manager-test.md" "$LEARNINGS" 2>/dev/null; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("learnings file missing provenance footer"); fi
if grep -q "^consolidated-into:" "$MEM/manager-test.md" 2>/dev/null; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("memory file missing consolidated-into marker"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
