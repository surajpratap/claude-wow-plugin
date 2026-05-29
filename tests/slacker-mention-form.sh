#!/usr/bin/env bash
# Story 156 — slacker.md doctrine must call out the <@U…> mention form
# for inbound author references and warn against bare @<handle>.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_grep() {
  local name="$1"; local pattern="$2"; local file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (pattern '$pattern' missing from $file)"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTRINE="$ROOT/commands/slacker.md"

assert_grep "mentions <@U…> form"      "<@U" "$DOCTRINE"
assert_grep "warns against bare @handle" "bare.*@.*handle|@handle.*bare|@<handle>" "$DOCTRINE"
assert_grep "Human-interactor registry section header" "## Human-interactor registry" "$DOCTRINE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
