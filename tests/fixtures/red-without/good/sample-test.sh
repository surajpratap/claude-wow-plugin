#!/usr/bin/env bash
# Fixture behavioral test (for red-without-lint's own verification). It spawns
# the trivial producer and asserts an observable effect (the token is emitted
# exactly once). good.patch reverts the producer's doubling guard so the
# "exactly once" case flips green->red — a GENUINE RED-WITHOUT.
#
# RED-WITHOUT: patch ../patches/good.patch -> g: token emitted exactly once
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PRODUCER="$HERE/producer.py"
PASS=0; FAIL=0; FAILED=()

COUNT="$(python3 "$PRODUCER" 3 | grep -c 'bus_emit token')"
if [ "$COUNT" = "1" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED+=("g: token emitted exactly once (got $COUNT)")
fi

echo "good-sample: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
