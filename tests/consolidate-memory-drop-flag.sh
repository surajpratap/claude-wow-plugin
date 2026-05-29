#!/usr/bin/env bash
# Story 158 — WOW_DROP_CONSOLIDATED_MEMORY=1 deletes memory file after
# consolidation; default OFF retains file with marker.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/consolidate-memory.sh"

run_case() {
  local case_name="$1" env_flag="$2" expect_exists="$3"
  local TMPDIR_FX
  TMPDIR_FX=$(mktemp -d)
  local ENCODED
  ENCODED=$(echo "$TMPDIR_FX" | sed 's|/|-|g')
  local MEM="$TMPDIR_FX/.claude/projects/$ENCODED/memory"
  mkdir -p "$MEM"
  cat > "$MEM/dropflag.md" <<'EOF'
---
name: drop-test-fact
metadata:
  role: tester
---
body
EOF
  if [ -n "$env_flag" ]; then
    WOW_DROP_CONSOLIDATED_MEMORY=1 WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" tester >/dev/null 2>&1
  else
    WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" tester >/dev/null 2>&1
  fi
  if [ -f "$MEM/dropflag.md" ]; then
    actual="exists"
  else
    actual="absent"
  fi
  if [ "$expect_exists" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$case_name (expected $expect_exists, got $actual)"); fi
  rm -rf "$TMPDIR_FX"
}

run_case "default (no env) → memory file retained with marker" "" "exists"
run_case "WOW_DROP_CONSOLIDATED_MEMORY=1 → memory file deleted" "set" "absent"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
