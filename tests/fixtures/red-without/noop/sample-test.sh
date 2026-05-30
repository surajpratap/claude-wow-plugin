#!/usr/bin/env bash
# Fixture behavioral test whose RED-WITHOUT patch is a NO-OP: noop.patch edits
# only a comment in producer.py, so this test stays GREEN under the revert. The
# lint MUST catch that (the patch did not make the named case go RED) -> the
# annotation is hollow. red-without-lint's selftest_noop asserts the catch.
#
# RED-WITHOUT: patch ../patches/noop.patch -> n: stable token emitted
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PRODUCER="$HERE/producer.py"
PASS=0; FAIL=0; FAILED=()

OUT="$(python3 "$PRODUCER")"
if printf '%s' "$OUT" | grep -q 'bus_emit stable-token'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED+=("n: stable token emitted")
fi

echo "noop-sample: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
