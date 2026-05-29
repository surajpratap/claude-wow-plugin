#!/usr/bin/env bash
# Bug 0003 FINDING-42 (MAJOR) regression guard.
# v3.29.0's phase_bootstrap called _emit_bus_tail_arm without checking
# its return code, then plowed through to emit_complete — agents saw a
# successful `complete` action even when an earlier arm-monitor abort
# was emitted. Inconsistent action stream.
#
# Story 161 wraps each helper call with `|| return 1` so phase_bootstrap
# bails on arm-helper failure. This test stubs bus-tail.sh to be
# unresolvable, runs startup.sh --role manager, and asserts:
#   - exit code is non-zero
#   - stdout contains exactly one `abort` action (from _emit_bus_tail_arm)
#   - stdout contains NO `complete` action

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

REAL_WOW_LOCATE=$(command -v wow-locate 2>/dev/null || true)
if [ -z "$REAL_WOW_LOCATE" ]; then
  echo "SKIP: wow-locate not on PATH" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations/.agents"
STUB=$(mktemp -d)

# wow-locate stub: returns empty for bus-tail.sh; delegates everything else.
cat > "$STUB/wow-locate" <<EOF
#!/usr/bin/env bash
# FINDING-42 test stub — fails bus-tail.sh resolution, delegates rest.
if [ "\$1" = "scripts/wow-process/bus-tail.sh" ]; then
  exit 1
fi
exec "$REAL_WOW_LOCATE" "\$@"
EOF
chmod +x "$STUB/wow-locate"

OUT=$(WOW_ROOT="$PROJ" PATH="$STUB:$PATH" bash "$STARTUP" --role manager 2>&1)
RC=$?

assert_eq "exit non-zero when bus-tail wrapper unresolvable" "1" "$RC"

abort_count=$(printf '%s\n' "$OUT" | grep -c '"action":"abort"' || true)
if [ "$abort_count" -ge 1 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("expected at least one abort action; got $abort_count")
fi

complete_count=$(printf '%s\n' "$OUT" | grep -c '"action":"complete"' || true)
assert_eq "NO complete action emitted after arm-helper failure (FINDING-42)" "0" "$complete_count"

if printf '%s' "$OUT" | grep -q "bus-tail wrapper not resolvable"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("abort reason should mention 'bus-tail wrapper not resolvable'")
fi

# Regression guard: phase_bootstrap.sh has `|| return 1` on every helper call
if grep -E '_emit_bus_tail_arm.*\|\|[[:space:]]+return 1' "$ROOT/scripts/startup/phase_bootstrap.sh" >/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("regression: _emit_bus_tail_arm call missing '|| return 1' (FINDING-42)")
fi

rm -rf "$PROJ" "$STUB"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
