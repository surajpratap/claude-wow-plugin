#!/usr/bin/env bash
# Story 152 — startup.sh flag parsing + JSONL output shape.
# Bad role → exit 2; --help → exit 0; --verify without tracker → exit 3.
# Every line printed on stdout parses as JSON.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations"
echo "falcon" > "$PROJ/implementations/.my-team"

# Case 1: unknown arg → exit 2
WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --bogus 2>/dev/null
assert_eq "case1: unknown arg exit 2" "2" "$?"

# Case 2: bad role → exit 2
WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --role bogus 2>/dev/null
assert_eq "case2: bad role exit 2" "2" "$?"

# Case 3: --help → exit 0
WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --help >/dev/null 2>&1
assert_eq "case3: --help exit 0" "0" "$?"

# Case 4: every stdout line is valid JSON for each role
for role in manager senior-developer pair-programmer tester slacker; do
  OUT=$(WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --role "$role" 2>/dev/null)
  bad_lines=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      bad_lines=$((bad_lines+1))
    fi
  done <<< "$OUT"
  assert_eq "case4: $role — all stdout lines valid JSON" "0" "$bad_lines"
  rm -rf "$PROJ/implementations/.agents" 2>/dev/null
done

rm -rf "$PROJ"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
