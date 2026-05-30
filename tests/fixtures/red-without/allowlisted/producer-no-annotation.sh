#!/usr/bin/env bash
# Fixture: producer-shape (bus_emit) with NO annotation, but listed on the
# fixture allowlist (grandfathered.txt) -> the lint must NOT flag it (reported
# as backlog instead). Proves the grandfather ratchet exempts the frozen set.
set -u
OUT="$(python3 -c "print('bus_emit grandfathered')")"
PASS=0; FAIL=0
printf '%s' "$OUT" | grep -q 'bus_emit' && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
echo "allowlisted-producer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
