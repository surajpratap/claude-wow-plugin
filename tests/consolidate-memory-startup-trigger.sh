#!/usr/bin/env bash
# Story 158 — startup phase invokes consolidation when memory file is
# newer than learnings file. Driven via startup.sh in isolation.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

TMPDIR_FX=$(mktemp -d)
mkdir -p "$TMPDIR_FX/implementations"
echo "falcon" > "$TMPDIR_FX/implementations/.my-team"

ENCODED=$(echo "$TMPDIR_FX" | sed 's|/|-|g')
MEM="$TMPDIR_FX/.claude/projects/$ENCODED/memory"
mkdir -p "$MEM"
cat > "$MEM/sd-fact.md" <<'EOF'
---
name: sd-startup-fact
metadata:
  role: senior-developer
---
body
EOF

SCRIPT_REAL="$ROOT/scripts/consolidate-memory.sh"
OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_PROJECT_DIR="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" WOW_CONSOLIDATE_SCRIPT="$SCRIPT_REAL" bash "$STARTUP" --role senior-developer 2>&1)

if echo "$OUT" | grep -q '"text":"consolidation: trigger'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("startup phase did not emit 'consolidation: trigger' info line"); fi

if echo "$OUT" | grep -q 'consolidation:.*entries_added'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("startup phase did not emit summary JSON"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
