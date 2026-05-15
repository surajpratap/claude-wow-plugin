#!/usr/bin/env bash
# plugin/tests/command-files-have-startup-sentinel.sh
# Every commands/<role>.md MUST open with a sentinel that matches its filename.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

for role in manager senior-developer pair-programmer tester slacker; do
  CMD="$PLUGIN_ROOT/commands/${role}.md"
  if [ ! -f "$CMD" ]; then
    fail "command-file-missing: $CMD"
    continue
  fi
  if head -5 "$CMD" | grep -qE "claude-wow-startup:[[:space:]]*${role}\b"; then
    pass
  else
    fail "sentinel-missing-or-wrong-role: $CMD"
  fi
done

echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
