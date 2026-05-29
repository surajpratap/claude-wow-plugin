#!/usr/bin/env bash
# Story 159 — bug-shape-check.sh passes on a conformant bug at each
# of the 8 statuses.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHAPE_CHECK="$ROOT/scripts/bug-shape-check.sh"

TMPDIR_FX=$(mktemp -d)
BUGS="$TMPDIR_FX/implementations/bugs"
mkdir -p "$BUGS"

write_bug() {
  local id="$1" status="$2" extra="$3"
  cat > "$BUGS/$id-test.md" <<EOF
<!-- status: $status -->
<!-- id: $id -->
<!-- reporter: test -->
<!-- reported-at: 2026-05-29T00:00:00Z -->
<!-- severity: medium -->
<!-- priority: P2 -->
<!-- affected-story: none -->
<!-- affected-version: 1.0.0 -->
$extra

# Bug $id — test
EOF
}

write_bug 0001 filed ""
WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
if [ $? -eq 0 ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILED_CASES+=("status:filed should pass shape-check"); fi

write_bug 0002 triaged "<!-- triaged-by: pp-test -->"
WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("status:triaged should pass"); }

write_bug 0003 fixing "<!-- triaged-by: pp -->
<!-- fixing-by: sd -->"
WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("status:fixing should pass"); }

write_bug 0004 fixed "<!-- triaged-by: pp -->
<!-- fixing-by: sd -->
<!-- fixed-by: sd -->
<!-- fixed-in: 1.0.1 -->
<!-- pr-url: https://github.com/x/y/pull/1 -->"
WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("status:fixed should pass"); }

write_bug 0005 verified "<!-- triaged-by: pp -->
<!-- fixing-by: sd -->
<!-- fixed-by: sd -->
<!-- fixed-in: 1.0.1 -->
<!-- pr-url: https://github.com/x/y/pull/1 -->
<!-- verified-by: t -->"
WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("status:verified should pass"); }

write_bug 0006 closed "<!-- triaged-by: pp -->
<!-- fixing-by: sd -->
<!-- fixed-by: sd -->
<!-- fixed-in: 1.0.1 -->
<!-- pr-url: https://github.com/x/y/pull/1 -->
<!-- verified-by: t -->
<!-- closed-at: 2026-05-29T01:00:00Z -->"
WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("status:closed should pass"); }

write_bug 0007 wont-fix "<!-- closed-at: 2026-05-29T01:00:00Z -->"
WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("status:wont-fix should pass"); }

write_bug 0008 duplicate "<!-- closed-at: 2026-05-29T01:00:00Z -->
<!-- duplicate-of: 0001 -->"
WOW_ROOT="$TMPDIR_FX" bash "$SHAPE_CHECK" >/dev/null 2>&1
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("status:duplicate should pass"); }

rm -rf "$TMPDIR_FX"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
