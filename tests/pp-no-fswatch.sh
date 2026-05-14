#!/usr/bin/env bash
# Asserts PP's role file + role-process-map entry contain ZERO references
# to fswatch.

set -u
PASS=0; FAIL=0; FAILED_CASES=()
assert_no_match() { local n="$1"; local pat="$2"; local file="$3"
  if ! grep -qiE "$pat" "$file"; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$n (unexpected match for '$pat' in $file)"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PP="$REPO_ROOT/commands/pair-programmer.md"
MAP="$REPO_ROOT/scripts/wow-process/role-process-map.json"

assert_no_match "pp-role-no-fswatch" 'fswatch' "$PP"

PP_ENTRY=$(jq -r '."pair-programmer" | tojson' "$MAP" 2>/dev/null)
case "$PP_ENTRY" in
  *fswatch*) FAIL=$((FAIL+1)); FAILED_CASES+=("pp-role-map-no-fswatch-peer (entry: $PP_ENTRY)") ;;
  *) PASS=$((PASS+1)) ;;
esac

if [ -f "$REPO_ROOT/scripts/wow-process/fswatch-peer.sh" ]; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("fswatch-peer-wrapper-still-exists")
else
  PASS=$((PASS+1))
fi

echo
echo "pp-no-fswatch: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
