#!/usr/bin/env bash
# Story 160 Layer F — inner suite runner. Invoked by the outer run-all.sh
# from within the run-all-sandbox.py session-leader wrapper.
#
# Holds the actual suite discovery + execution + plan-shape-gate +
# bug-shape-check gate + structural self-check. Same logic that used to
# live in run-all.sh; only difference is the self-check now excludes
# BOTH run-all.sh and run-all-inner.sh from the present-tests set.
#
# Modes:
#   (no flag)   Run every suite under tests/*.sh.
#   --quick     In-sprint mode. Run only suites that are likely affected
#               by the current branch's changes since HEAD~1, plus
#               version-coherence (always). Falls back to a full run if
#               HEAD~1 doesn't exist or no changes are detected.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$(basename "$0")"
QUICK=0

# Per-test timeout: a single test cannot block the suite forever. Default
# 5 minutes is generous for any current test; env-overridable.
TEST_TIMEOUT_S="${WOW_TEST_TIMEOUT_S:-300}"
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"

show_help() {
  cat <<'HELP'
Usage: tests/run-all.sh [--quick]

  (no flag)   Run all suites under tests/*.sh.
  --quick     In-sprint mode. Run only suites that:
              - are themselves modified since HEAD~1, OR
              - mention any file changed since HEAD~1 by basename, OR
              - are tests/version-coherence.sh (always).
              Falls back to a full run if HEAD~1 doesn't exist or no
              changes are detected (with a stderr note).
HELP
}

case "${1:-}" in
  --quick) QUICK=1; shift ;;
  --help|-h) show_help; exit 0 ;;
  "") ;;
  *) printf 'unknown flag: %s\n' "$1" >&2; show_help >&2; exit 2 ;;
esac

# Compute the suite list. Exclude BOTH run-all.sh + run-all-inner.sh from
# the discovered set (Story 160 split — inner runner is not a test).
SUITES=()
ALL_SUITES=()
for script in "$DIR"/*.sh; do
  [ -f "$script" ] || continue
  b="$(basename "$script")"
  case "$b" in
    run-all.sh|run-all-inner.sh|"$SELF") continue ;;
  esac
  ALL_SUITES+=("$script")
done

if [ "$QUICK" = "1" ]; then
  CHANGED_FILES="$(git -C "$DIR/.." diff --name-only HEAD~1 HEAD 2>/dev/null)"
  if [ -z "$CHANGED_FILES" ]; then
    printf 'run-all-inner.sh: --quick fell through to full run (no changes since HEAD~1)\n' >&2
    SUITES=("${ALL_SUITES[@]}")
  else
    CHANGED_BASENAMES="$(printf '%s\n' "$CHANGED_FILES" | xargs -n1 basename 2>/dev/null | sort -u)"
    for suite in "${ALL_SUITES[@]}"; do
      include=0
      suite_relpath="tests/$(basename "$suite")"
      if printf '%s\n' "$CHANGED_FILES" | grep -qxF "$suite_relpath"; then
        include=1
      else
        for bn in $CHANGED_BASENAMES; do
          if grep -qF "$bn" "$suite"; then
            include=1
            break
          fi
        done
      fi
      [ "$include" = "1" ] && SUITES+=("$suite")
    done
    vc_path="$DIR/version-coherence.sh"
    case " ${SUITES[*]:-} " in
      *" $vc_path "*) ;;
      *) [ -f "$vc_path" ] && SUITES+=("$vc_path") ;;
    esac
    printf 'run-all-inner.sh: --quick selected %d of %d suites\n' "${#SUITES[@]}" "${#ALL_SUITES[@]}" >&2
  fi
else
  SUITES=("${ALL_SUITES[@]}")
fi

SUITES_PASSED=0
SUITES_FAILED=0
FAILED_SUITES=()

# Story 160: each test gets a per-test timeout wrapper. If `timeout(1)` is
# missing (degenerate environment), no-op — the ulimit + session-reap still
# bound the worst case.
run_one() {
  local script="$1"
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TEST_TIMEOUT_S" bash "$script"
    return $?
  fi
  bash "$script"
}

for script in "${SUITES[@]}"; do
  name="$(basename "$script")"
  echo "=== $name ==="
  run_one "$script"; rc=$?
  if [ "$rc" -eq 0 ]; then
    SUITES_PASSED=$((SUITES_PASSED+1))
  elif [ "$rc" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
    echo "[run-all-inner.sh] $name exceeded WOW_TEST_TIMEOUT_S=${TEST_TIMEOUT_S}s — killed by timeout (exit 124)" >&2
    SUITES_FAILED=$((SUITES_FAILED+1))
    FAILED_SUITES+=("$name (timeout)")
  else
    SUITES_FAILED=$((SUITES_FAILED+1))
    FAILED_SUITES+=("$name")
  fi
  echo
done

_psg="$DIR/../scripts/plan-shape-gate.sh"
if [ -f "$_psg" ]; then
  _psg_top=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || echo "$DIR/../..")
  _psg_out=$(bash "$_psg" "$_psg_top" 2>&1); _psg_rc=$?
  if [ "$_psg_rc" -ne 0 ]; then
    echo "=== plan-shape-gate (FAILED) ==="
    printf '%s\n' "$_psg_out" | sed 's/^/  /'
    SUITES_FAILED=$((SUITES_FAILED+1)); FAILED_SUITES+=("plan-shape-gate")
  fi
fi

_bsc="$DIR/../scripts/bug-shape-check.sh"
if [ -f "$_bsc" ]; then
  _bsc_top=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || echo "$DIR/../..")
  _bsc_out=$(WOW_ROOT="$_bsc_top" bash "$_bsc" 2>&1); _bsc_rc=$?
  if [ "$_bsc_rc" -ne 0 ]; then
    echo "=== bug-shape-check (FAILED) ==="
    printf '%s\n' "$_bsc_out" | sed 's/^/  /'
    SUITES_FAILED=$((SUITES_FAILED+1)); FAILED_SUITES+=("bug-shape-check")
  fi
fi

echo "=== summary ==="
echo "suites passed: $SUITES_PASSED"
echo "suites failed: $SUITES_FAILED"

SELF_CHECK_FAIL=0
if [ "$QUICK" = "0" ]; then
  present_set=$(for f in "$DIR"/*.sh; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    case "$b" in
      (run-all.sh|run-all-inner.sh|"$SELF") continue ;;
    esac
    echo "$b"
  done | sort)
  executed_set=$(for s in "${SUITES[@]}"; do basename "$s"; done | sort)
  if [ "$present_set" != "$executed_set" ]; then
    echo "suite self-check: FAILED - executed suite set != present tests/*.sh set"
    SELF_CHECK_FAIL=1
  else
    echo "suite self-check: ok ($(printf '%s\n' "$present_set" | grep -c .) suites)"
  fi
fi

if [ "$SUITES_FAILED" -ne 0 ]; then
  echo "failed suites:"
  for s in "${FAILED_SUITES[@]}"; do
    echo "  - $s"
  done
  exit 1
fi
[ "$SELF_CHECK_FAIL" -ne 0 ] && exit 1
exit 0
