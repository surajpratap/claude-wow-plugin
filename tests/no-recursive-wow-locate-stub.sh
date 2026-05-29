#!/usr/bin/env bash
# Bug 0002, Layer D — test convention lint.
# A test that creates a wow-locate stub MUST capture
# REAL_WOW_LOCATE=$(command -v wow-locate) before the stub creation so
# the stub can delegate to the REAL wow-locate (not call itself
# recursively via PATH). This lint scans every plugin/tests/*.sh and
# fails on any stub that delegates to bare wow-locate without a
# matching REAL_WOW_LOCATE= capture earlier in the same file.
#
# Pattern signals (any of):
#   "wow-locate" "$@"   inside a stub
#   wow-locate "$@"     same, unquoted
#   exec wow-locate
#   `wow-locate ...` or $(wow-locate ...) inside a stub heredoc
#
# Required (anywhere earlier in same file):
#   REAL_WOW_LOCATE=$(command -v wow-locate)
#   or REAL_WOW_LOCATE=$(which wow-locate)
#   or REAL_WOW_LOCATE=...    (any var assignment NAMED REAL_WOW_LOCATE)

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# lint a single test file. Echoes "VIOLATION" if the file creates a
# stub that delegates to bare wow-locate without a REAL_WOW_LOCATE
# capture; echoes nothing if clean.
lint_test_file() {
  local f="$1"
  # Quick reject: skip files that don't create any wow-locate stub.
  if ! grep -qE "wow-locate" "$f"; then
    return 0
  fi
  # Self-exemption: this lint file itself + the recursion-guard test
  # have intentional wow-locate references that are NOT stubs.
  case "$(basename "$f")" in
    no-recursive-wow-locate-stub.sh|wow-locate-recursion-guard.sh|wow-locate-resolver.sh)
      return 0
      ;;
  esac
  # Look for bare delegation patterns inside the file
  local has_bare=0
  if grep -qE '(^|[^"])wow-locate[[:space:]]+("\$@"|"\$1")' "$f"; then
    has_bare=1
  elif grep -qE 'exec[[:space:]]+wow-locate' "$f"; then
    has_bare=1
  fi
  if [ "$has_bare" -eq 0 ]; then
    return 0
  fi
  # Bare delegation detected — require REAL_WOW_LOCATE= capture earlier
  if grep -qE 'REAL_WOW_LOCATE=' "$f"; then
    return 0
  fi
  echo "VIOLATION: $f has a bare wow-locate stub delegation without a REAL_WOW_LOCATE= capture"
  return 1
}

# Lint every test file
violations=0
for f in "$SCRIPT_DIR"/*.sh; do
  [ -f "$f" ] || continue
  if ! out=$(lint_test_file "$f"); then
    violations=$((violations+1))
    echo "$out"
  fi
done
assert_eq "lint-clean: zero violations across plugin/tests/*.sh" "0" "$violations"

# Negative test: construct a fixture with a violation and confirm the lint catches it
TMP=$(mktemp -d)
cat > "$TMP/bad-test.sh" <<'EOF'
#!/usr/bin/env bash
# Synthetic bad fixture — creates a wow-locate stub without REAL_WOW_LOCATE
PATH_OVERRIDE=$(mktemp -d)
cat > "$PATH_OVERRIDE/wow-locate" <<'INNER'
#!/usr/bin/env bash
exec wow-locate "$@"
INNER
chmod +x "$PATH_OVERRIDE/wow-locate"
EOF
out=$(lint_test_file "$TMP/bad-test.sh")
RC=$?
assert_eq "neg-test-1: bad fixture flagged" "1" "$RC"
case "$out" in
  *VIOLATION*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); FAILED_CASES+=("neg-test-1: bad fixture didn't emit VIOLATION (got: $out)") ;;
esac
rm -rf "$TMP"

# Positive test: fixture WITH REAL_WOW_LOCATE capture passes the lint
TMP=$(mktemp -d)
cat > "$TMP/good-test.sh" <<'EOF'
#!/usr/bin/env bash
REAL_WOW_LOCATE=$(command -v wow-locate)
PATH_OVERRIDE=$(mktemp -d)
cat > "$PATH_OVERRIDE/wow-locate" <<INNER
#!/usr/bin/env bash
exec "$REAL_WOW_LOCATE" "\$@"
INNER
chmod +x "$PATH_OVERRIDE/wow-locate"
EOF
out=$(lint_test_file "$TMP/good-test.sh")
RC=$?
assert_eq "pos-test-1: good fixture passes" "0" "$RC"
rm -rf "$TMP"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
