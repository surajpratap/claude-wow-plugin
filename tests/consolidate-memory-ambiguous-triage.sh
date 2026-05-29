#!/usr/bin/env bash
# Story 158 — entry with no role signal → triage file gets entry; learnings file untouched.

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
cat > "$MEM/ambig.md" <<'EOF'
---
name: ambiguous-fact
---

A general fact that doesn't mention any specific role.
EOF

OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" manager 2>&1)
ADDED=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['entries_added'])")
TRIAGE=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['triage_count'])")

assert_eq "entries_added=0" "0" "$ADDED"
assert_eq "triage_count=1" "1" "$TRIAGE"

TRIAGE_FILE="$TMPDIR_FX/implementations/learnings/.consolidate-needs-triage.md"
if [ -f "$TRIAGE_FILE" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("triage file not created"); fi

LEARNINGS="$TMPDIR_FX/implementations/learnings/manager.md"
if [ ! -f "$LEARNINGS" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("learnings file should not have been created"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
