#!/usr/bin/env bash
# Run every test under tests/ except this script itself. Each test exits 0
# on pass, non-zero on fail. Aggregates pass/fail counts.
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

# Story 144: OPT-IN serialization (default OFF — normal run-all is unchanged).
# Set WOW_RUNALL_SERIALIZE=1 to source the lock (re-exec under the python wrapper
# so concurrent run-all serialize instead of resource/OOM-contending). The lock
# is a tool peers/CI opt into, NOT forced on every run-all. Sourced before
# arg-parse so the re-exec preserves the original "$@".
# shellcheck source=../scripts/run-all-lock.sh
[ "${WOW_RUNALL_SERIALIZE:-}" = "1" ] && . "$DIR/../scripts/run-all-lock.sh"

case "${1:-}" in
  --quick) QUICK=1; shift ;;
  --help|-h) show_help; exit 0 ;;
  "") ;;
  *) printf 'unknown flag: %s\n' "$1" >&2; show_help >&2; exit 2 ;;
esac

# Compute the suite list.
SUITES=()
ALL_SUITES=()
for script in "$DIR"/*.sh; do
  [ -f "$script" ] || continue
  [ "$(basename "$script")" = "$SELF" ] && continue
  ALL_SUITES+=("$script")
done

if [ "$QUICK" = "1" ]; then
  CHANGED_FILES="$(git -C "$DIR/.." diff --name-only HEAD~1 HEAD 2>/dev/null)"
  if [ -z "$CHANGED_FILES" ]; then
    printf 'run-all.sh: --quick fell through to full run (no changes since HEAD~1)\n' >&2
    SUITES=("${ALL_SUITES[@]}")
  else
    CHANGED_BASENAMES="$(printf '%s\n' "$CHANGED_FILES" | xargs -n1 basename 2>/dev/null | sort -u)"
    for suite in "${ALL_SUITES[@]}"; do
      include=0
      suite_relpath="tests/$(basename "$suite")"
      # rule 1: suite itself was modified
      if printf '%s\n' "$CHANGED_FILES" | grep -qxF "$suite_relpath"; then
        include=1
      else
        # rule 2: suite mentions any changed-file basename
        for bn in $CHANGED_BASENAMES; do
          if grep -qF "$bn" "$suite"; then
            include=1
            break
          fi
        done
      fi
      [ "$include" = "1" ] && SUITES+=("$suite")
    done
    # rule 3: always include version-coherence
    vc_path="$DIR/version-coherence.sh"
    case " ${SUITES[*]:-} " in
      *" $vc_path "*) ;;
      *) [ -f "$vc_path" ] && SUITES+=("$vc_path") ;;
    esac
    printf 'run-all.sh: --quick selected %d of %d suites\n' "${#SUITES[@]}" "${#ALL_SUITES[@]}" >&2
  fi
else
  SUITES=("${ALL_SUITES[@]}")
fi

SUITES_PASSED=0
SUITES_FAILED=0
FAILED_SUITES=()

for script in "${SUITES[@]}"; do
  name="$(basename "$script")"
  echo "=== $name ==="
  if bash "$script"; then
    SUITES_PASSED=$((SUITES_PASSED+1))
  else
    SUITES_FAILED=$((SUITES_FAILED+1))
    FAILED_SUITES+=("$name")
  fi
  echo
done

# Story 147: diff-scoped plan-shape auto-gate — run plan-shape-check.sh on the
# branch's MODIFIED plans (git-toplevel scope) so a missing `## AC count` is
# caught automatically, no one having to remember. A flagged plan fails run-all.
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

echo "=== summary ==="
echo "suites passed: $SUITES_PASSED"
echo "suites failed: $SUITES_FAILED"

# Full-mode structural self-check: the SET of suites executed must equal the SET
# of tests/*.sh files present (run-all.sh excluded). Catches a future discovery
# filter that drops a suite -- including a drop-B-double-run-A swap that leaves
# the bare count unchanged. --quick runs a subset by design, so it is exempt.
SELF_CHECK_FAIL=0
if [ "$QUICK" = "0" ]; then
  present_set=$(for f in "$DIR"/*.sh; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = "$SELF" ] && continue
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
