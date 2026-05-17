#!/usr/bin/env bash
# Asserts the M attention sound ships and the Story-081 hook/marker layer is gone
# (Story 084): the wow-attention player exists + is executable, the bundled WAV is
# present, and no Notification hook is registered.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # = plugin/
FAIL=0
fail() { echo "ERROR: $1" >&2; FAIL=1; }

# --- kept artifacts -----------------------------------------------------
[ -f "$REPO_ROOT/bin/wow-attention" ]      || fail "bin/wow-attention not found"
[ -x "$REPO_ROOT/bin/wow-attention" ]      || fail "bin/wow-attention is not executable"
[ -f "$REPO_ROOT/assets/attention.wav" ]   || fail "assets/attention.wav not found"

# --- removal regression guards ------------------------------------------
[ ! -f "$REPO_ROOT/scripts/hooks/wow-attention-notify.sh" ] \
  || fail "scripts/hooks/wow-attention-notify.sh should have been removed (Story 084)"
if grep -q '"Notification"' "$REPO_ROOT/hooks/hooks.json" 2>/dev/null; then
  fail "hooks.json still registers a Notification hook (Story 084 removed it)"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "attention-sound: FAIL" >&2
  exit 1
fi
echo "attention-sound: PASS"
exit 0
