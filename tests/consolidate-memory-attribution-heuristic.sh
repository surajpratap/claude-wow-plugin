#!/usr/bin/env bash
# Story 158 — 4-path attribution heuristic: each path classifies a memory
# entry as in-scope when the role matches.

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

run_case() {
  local case_name="$1" role="$2" filename="$3" content="$4"
  local TMPDIR_FX
  TMPDIR_FX=$(mktemp -d)
  local ENCODED
  ENCODED=$(echo "$TMPDIR_FX" | sed 's|/|-|g')
  local MEM="$TMPDIR_FX/.claude/projects/$ENCODED/memory"
  mkdir -p "$MEM"
  printf '%s' "$content" > "$MEM/$filename"
  local OUT
  OUT=$(WOW_ROOT="$TMPDIR_FX" CLAUDE_CONFIG_DIR="$TMPDIR_FX/.claude" bash "$SCRIPT" "$role" 2>&1)
  local ADDED
  ADDED=$(echo "$OUT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['entries_added'])")
  assert_eq "$case_name" "1" "$ADDED"
  rm -rf "$TMPDIR_FX"
}

# (a) frontmatter metadata.role
run_case "heuristic-a-frontmatter" "manager" "x.md" "---
name: a-fact
metadata:
  role: manager
---
body
"

# (b) body [role: X] marker
run_case "heuristic-b-body-marker" "tester" "y.md" "---
name: b-fact
---
[role: tester] this is a tester-specific note.
"

# (c) exactly-one-role mention
run_case "heuristic-c-one-role-mention" "pair-programmer" "z.md" "---
name: c-fact
---
The pair-programmer reviews plans. That's it.
"

# (d) filename prefix
run_case "heuristic-d-filename-prefix" "slacker" "slacker-fact.md" "---
name: d-fact
---
A slack-related note.
"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
