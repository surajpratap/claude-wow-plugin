#!/usr/bin/env bash
# Story 159 — duplicate-of pointing at nonexistent bug fails shape-check.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHAPE_CHECK="$ROOT/scripts/bug-shape-check.sh"

TMPDIR_FX=$(mktemp -d)
BUGS="$TMPDIR_FX/implementations/bugs"
mkdir -p "$BUGS"

cat > "$BUGS/0001-dup.md" <<'EOF'
<!-- status: duplicate -->
<!-- id: 0001 -->
<!-- reporter: t -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- severity: medium -->
<!-- priority: P2 -->
<!-- affected-story: none -->
<!-- affected-version: 1.0.0 -->
<!-- closed-at: 2026-05-29T01:00:00Z -->
<!-- duplicate-of: 9999 -->

# x
EOF

OUT=$(WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("duplicate-of nonexistent should fail; got rc=$RC"); fi
if echo "$OUT" | grep -q "references nonexistent bug"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("diagnostic should mention 'nonexistent'"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
