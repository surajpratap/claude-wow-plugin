#!/usr/bin/env bash
# Bug 0003 FINDING-40 (BLOCKER) regression guard.
# v3.29.0 shipped startup.sh with `if ! phase_X; then return 0; fi`
# pattern — phase failure became silent startup success. Story 161
# rewrote run_phases as a case statement:
#   rc=0  → continue
#   rc=10 → clean ask-human handoff (return 0)
#   else  → genuine failure → emit_abort + return 1 → exit non-zero
#
# This test forces a phase to fail and asserts startup.sh exits
# non-zero + emits an `abort` action line.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}
assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name (haystack missing '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"
STARTUP_LIB="$ROOT/scripts/startup"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations"
echo "falcon" > "$PROJ/implementations/.my-team"

# Case 1: stub phase_env to return 1 (genuine failure). startup.sh
# must exit non-zero + emit abort. We override the phase by placing
# a fake phase_env.sh in an ALT path + patching the startup copy to
# source from ALT instead.
ALT=$(mktemp -d)
cp -R "$STARTUP_LIB"/*.sh "$ALT/" 2>/dev/null
cat > "$ALT/phase_env.sh" <<'EOF'
phase_env() {
  emit_info "fake-phase_env: forcing failure (rc=1)"
  return 1
}
EOF

cp "$STARTUP" "$ALT/startup.sh"
sed -i.bak "s|STARTUP_LIB_DIR=\"\$SCRIPT_DIR/startup\"|STARTUP_LIB_DIR=\"$ALT\"|" "$ALT/startup.sh"
rm -f "$ALT/startup.sh.bak"

OUT=$(WOW_ROOT="$PROJ" bash "$ALT/startup.sh" --role manager 2>&1)
RC=$?

assert_eq "case1: forced phase failure → exit non-zero" "1" "$RC"
assert_contains "case1: abort action emitted" '"action":"abort"' "$OUT"
assert_contains "case1: abort mentions rc=1" "rc=1" "$OUT"
if printf '%s' "$OUT" | grep -q '"action":"complete"'; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case1: complete emitted DESPITE phase failure (FINDING-40 not closed)")
else
  PASS=$((PASS+1))
fi

# Case 2: regression guard — confirm the new case statement exists
if grep -q 'case "$rc" in' "$STARTUP"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case2: run_phases case statement missing (FINDING-40 regression)")
fi

# Case 3: rc=10 ask-human handoff returns 0 (no abort)
cat > "$ALT/phase_env.sh" <<'EOF'
phase_env() {
  emit_info "fake-phase_env: ask-human handoff sentinel"
  return 10
}
EOF
OUT=$(WOW_ROOT="$PROJ" bash "$ALT/startup.sh" --role manager 2>&1)
RC=$?
assert_eq "case3: rc=10 sentinel → exit 0" "0" "$RC"
if printf '%s' "$OUT" | grep -q '"action":"abort"'; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("case3: rc=10 falsely emitted abort")
else
  PASS=$((PASS+1))
fi

rm -rf "$PROJ" "$ALT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
