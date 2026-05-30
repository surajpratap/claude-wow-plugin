#!/usr/bin/env bash
# Fixture: producer-shape (spawns a producer that prints the trigger token) but
# carries NO annotation and is NOT on the allowlist -> the lint MUST flag it as
# a missing-annotation behavioral test (the ratchet for a NEW behavioral test).
# (This header avoids the annotation marker so the file genuinely lacks one.)
set -u
OUT="$(python3 -c "print('bus_emit something')")"
PASS=0; FAIL=0
printf '%s' "$OUT" | grep -q 'bus_emit' && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
echo "missing-producer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
