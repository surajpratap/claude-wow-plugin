#!/usr/bin/env bash
# Story 159 — id marker mismatched with filename prefix fails shape-check.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHAPE_CHECK="$ROOT/scripts/bug-shape-check.sh"

TMPDIR_FX=$(mktemp -d)
BUGS="$TMPDIR_FX/implementations/bugs"
mkdir -p "$BUGS"

cat > "$BUGS/0001-mismatch.md" <<'EOF'
<!-- status: filed -->
<!-- id: 9999 -->
<!-- reporter: t -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- severity: high -->
<!-- priority: P1 -->
<!-- affected-story: none -->
<!-- affected-version: 1.0.0 -->

# Bug — mismatched id
EOF

OUT=$(WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("id mismatch should fail; got rc=$RC"); fi
if echo "$OUT" | grep -q "does not match filename prefix"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("diagnostic should mention 'filename prefix'"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
