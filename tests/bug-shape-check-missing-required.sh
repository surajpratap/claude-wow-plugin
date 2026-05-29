#!/usr/bin/env bash
# Story 159 — bug missing a required marker per its status fails shape-check.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHAPE_CHECK="$ROOT/scripts/bug-shape-check.sh"

TMPDIR_FX=$(mktemp -d)
BUGS="$TMPDIR_FX/implementations/bugs"
mkdir -p "$BUGS"

# Status filed, missing 'severity'
cat > "$BUGS/0001-x.md" <<'EOF'
<!-- status: filed -->
<!-- id: 0001 -->
<!-- reporter: t -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- priority: P1 -->
<!-- affected-story: none -->
<!-- affected-version: 1.0.0 -->

# Bug 0001 — missing severity
EOF

OUT=$(WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" 2>&1)
RC=$?
if [ $RC -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("missing severity should fail; got rc=$RC"); fi
if echo "$OUT" | grep -q "missing required marker 'severity'"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("diagnostic should name 'severity'"); fi

# Status closed, missing 'closed-at'
cat > "$BUGS/0002-y.md" <<'EOF'
<!-- status: closed -->
<!-- id: 0002 -->
<!-- reporter: t -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- severity: medium -->
<!-- priority: P2 -->
<!-- affected-story: none -->
<!-- affected-version: 1.0.0 -->
<!-- triaged-by: pp -->
<!-- fixing-by: sd -->
<!-- fixed-by: sd -->
<!-- fixed-in: 1.0.1 -->
<!-- pr-url: https://github.com/x/y/pull/1 -->
<!-- verified-by: t -->

# Bug 0002 — missing closed-at
EOF

rm -f "$BUGS/0001-x.md"
OUT=$(WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" 2>&1)
RC=$?
if [ $RC -ne 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("closed without closed-at should fail; got rc=$RC"); fi
if echo "$OUT" | grep -q "closed-at"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("diagnostic should name closed-at"); fi

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
