#!/usr/bin/env bash
# Story 158 — entry name already present as H3 in learnings → skipped + marked.

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
mkdir -p "$TMPDIR_FX/implementations/learnings"
# Seed an existing learnings file with the H3 heading we'll try to dedup.
cat > "$TMPDIR_FX/implementations/learnings/manager.md" <<'EOF'
# Manager learnings

## Pre-existing section

### already-known-fact

This was already here.
EOF

cat > "$MEM/x.md" <<'EOF'
---
name: already-known-fact
metadata:
  role: manager
---
body would otherwise be appended
EOF

OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" manager 2>&1)
ADDED=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['entries_added'])")
SKIPPED=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['entries_skipped'])")

assert_eq "dedup: entries_added=0" "0" "$ADDED"
assert_eq "dedup: entries_skipped=1" "1" "$SKIPPED"
if grep -q "^consolidated-into:" "$MEM/x.md" 2>/dev/null; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("memory file should be marked even on dedup"); fi
# Existing H3 should still be the only one
H3_COUNT=$(grep -c "^### already-known-fact" "$TMPDIR_FX/implementations/learnings/manager.md")
assert_eq "exactly one H3 (no append)" "1" "$H3_COUNT"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
