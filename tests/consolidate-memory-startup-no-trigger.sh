#!/usr/bin/env bash
# Story 158 — startup phase skips when memory dir is absent OR memory file
# is older than learnings file.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

TMPDIR_FX=$(mktemp -d)
mkdir -p "$TMPDIR_FX/implementations"
echo "falcon" > "$TMPDIR_FX/implementations/.my-team"

SCRIPT_REAL="$ROOT/scripts/consolidate-memory.sh"

# No memory dir → expect skip line
OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude-empty" WOW_CONSOLIDATE_SCRIPT="$SCRIPT_REAL" bash "$STARTUP" --role senior-developer 2>&1)
if echo "$OUT" | grep -q '"text":"consolidation: skip (no memory dir'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("no-memory-dir case did not emit skip line"); fi

# Memory file older than learnings → expect skip
ENCODED=$(echo "$TMPDIR_FX" | sed 's|/|-|g')
MEM="$TMPDIR_FX/.claude/projects/$ENCODED/memory"
mkdir -p "$MEM" "$TMPDIR_FX/implementations/learnings"
cat > "$MEM/old.md" <<'EOF'
---
name: old-fact
metadata:
  role: senior-developer
---
body
EOF
# Backdate the memory file 1 hour
PAST=$(($(date +%s) - 3600))
touch -t "$(date -r $PAST '+%Y%m%d%H%M.%S')" "$MEM/old.md"
# Touch learnings to "now"
touch "$TMPDIR_FX/implementations/learnings/senior-developer.md"

OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" WOW_CONSOLIDATE_SCRIPT="$SCRIPT_REAL" bash "$STARTUP" --role senior-developer 2>&1)
if echo "$OUT" | grep -q '"text":"consolidation: skip (no memory file newer'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("older-memory case did not emit skip line"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
