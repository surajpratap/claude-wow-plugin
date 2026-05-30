#!/usr/bin/env bash
# Fixture SHAPE-ONLY test: it only greps a file for a literal string. It spawns
# no producer at all, so it must NOT match the behavioral heuristic, and the
# lint must NOT demand an annotation of it. (This header is deliberately free of
# the producer-shape trigger tokens so it does not self-match the heuristic.)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
if grep -q 'shape-only' "$HERE/shape-only-test.sh"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
echo "exclude-shape-only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
