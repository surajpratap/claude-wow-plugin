#!/usr/bin/env bash
# Story 086 - verifies run-all-inner.sh's full-mode suite-set self-check.
# Positive: real run-all-inner.sh over a fixture of N suites exits 0 with a set match.
# Negative: a run-all-inner.sh whose discovery loop drops a suite exits non-zero.
#
# Story 160 split: run-all.sh is now a thin outer sandbox wrapper; the
# self-check logic lives in run-all-inner.sh. We test run-all-inner.sh
# directly — the outer wrapper is exercised by separate sandbox tests.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # = plugin/
RUN_ALL_INNER="$REPO_ROOT/tests/run-all-inner.sh"
FAIL=0
fail() { echo "ERROR: $1" >&2; FAIL=1; }

[ -f "$RUN_ALL_INNER" ] || { echo "ERROR: run-all-inner.sh not found" >&2; exit 1; }

make_fixture() {   # $1 = dir; seeds 3 trivial passing suites
  mkdir -p "$1"
  for n in 1 2 3; do
    printf '#!/usr/bin/env bash\necho "fixture suite %s"\nexit 0\n' "$n" > "$1/suite$n.sh"
    chmod +x "$1/suite$n.sh"
  done
}

# --- positive: real run-all-inner.sh, executed set == present set -> exit 0 ---
POS="$(mktemp -d)"
make_fixture "$POS"
cp "$RUN_ALL_INNER" "$POS/run-all-inner.sh"
if out=$(cd "$POS" && bash run-all-inner.sh 2>&1); then
  printf '%s\n' "$out" | grep -q 'suite self-check: ok (3 suites)' \
    || fail "positive case: self-check 'ok (3 suites)' line missing from summary"
else
  fail "positive case: run-all-inner.sh exited non-zero on a clean 3-suite fixture"
fi
rm -rf "$POS"

# --- negative: sabotaged discovery (drops one suite) -> exit non-zero -------
NEG="$(mktemp -d)"
make_fixture "$NEG"
# Sabotage: inject a line dropping the first discovered suite, just before the
# QUICK branch. awk -- portable line insertion (a sed newline-in-replacement is
# not portable across BSD/GNU sed).
awk '/^if \[ "\$QUICK" = "1" \]; then/ && !injected { print "ALL_SUITES=(\"${ALL_SUITES[@]:1}\")"; injected=1 } { print }' \
  "$RUN_ALL_INNER" > "$NEG/run-all-inner.sh"
chmod +x "$NEG/run-all-inner.sh"
# A no-op sabotage must NOT read as a pass: confirm the line actually landed.
grep -qF 'ALL_SUITES=("${ALL_SUITES[@]:1}")' "$NEG/run-all-inner.sh" \
  || fail "negative case: sabotage line was not injected -- fixture run-all-inner.sh unchanged"
if (cd "$NEG" && bash run-all-inner.sh >/dev/null 2>&1); then
  fail "negative case: sabotaged run-all-inner.sh exited 0 -- self-check did not fire"
else
  out=$(cd "$NEG" && bash run-all-inner.sh 2>&1 || true)
  printf '%s\n' "$out" | grep -q 'suite self-check: FAILED' \
    || fail "negative case: 'suite self-check: FAILED' line missing"
fi
rm -rf "$NEG"

if [ "$FAIL" -ne 0 ]; then
  echo "run-all-self-check: FAIL" >&2
  exit 1
fi
echo "run-all-self-check: PASS"
exit 0
