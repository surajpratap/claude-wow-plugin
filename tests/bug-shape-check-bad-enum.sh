#!/usr/bin/env bash
# Story 159 — bad severity / priority / status enum values fail shape-check.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHAPE_CHECK="$ROOT/scripts/bug-shape-check.sh"

TMPDIR_FX=$(mktemp -d)
BUGS="$TMPDIR_FX/implementations/bugs"
mkdir -p "$BUGS"

run_case() {
  local case_name="$1" file_content="$2" expect_pattern="$3"
  rm -f "$BUGS/0001-x.md"
  printf '%s' "$file_content" > "$BUGS/0001-x.md"
  OUT=$(WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" 2>&1)
  RC=$?
  if [ $RC -ne 0 ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$case_name should fail; got rc=$RC"); fi
  if echo "$OUT" | grep -q "$expect_pattern"; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$case_name diagnostic should match '$expect_pattern'"); fi
}

run_case "bad severity 'critical'" "$(cat <<'EOF'
<!-- status: filed -->
<!-- id: 0001 -->
<!-- reporter: t -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- severity: critical -->
<!-- priority: P1 -->
<!-- affected-story: none -->
<!-- affected-version: 1.0.0 -->

# x
EOF
)" "unknown severity"

run_case "bad priority 'urgent'" "$(cat <<'EOF'
<!-- status: filed -->
<!-- id: 0001 -->
<!-- reporter: t -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- severity: high -->
<!-- priority: urgent -->
<!-- affected-story: none -->
<!-- affected-version: 1.0.0 -->

# x
EOF
)" "unknown priority"

run_case "bad status 'open'" "$(cat <<'EOF'
<!-- status: open -->
<!-- id: 0001 -->
<!-- reporter: t -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- severity: high -->
<!-- priority: P1 -->
<!-- affected-story: none -->
<!-- affected-version: 1.0.0 -->

# x
EOF
)" "unknown status"

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
