#!/usr/bin/env bash
# Story 158 — second run on an already-marked file is a no-op.

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
cat > "$MEM/t.md" <<'EOF'
---
name: fact-x
metadata:
  role: senior-developer
---
body
EOF

# First run
WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" senior-developer >/dev/null 2>&1
# Second run
OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" senior-developer 2>&1)
ADDED=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['entries_added'])")
SKIPPED=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['entries_skipped'])")

assert_eq "second run entries_added=0 (idempotent)" "0" "$ADDED"
assert_eq "second run entries_skipped=1 (already-marked)" "1" "$SKIPPED"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
