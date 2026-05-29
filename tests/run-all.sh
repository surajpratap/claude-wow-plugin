#!/usr/bin/env bash
# Story 160 Layer F — process-group sandbox wrapper.
#
# This thin outer wrapper:
#  1. Applies ulimit -u so a runaway test errors at WOW_TEST_PROC_BUDGET
#     (default 500) instead of the user's host-wide ~10k limit.
#  2. Optionally sources Story 144's run-all-lock when WOW_RUNALL_SERIALIZE=1.
#  3. exec's plugin/scripts/run-all-sandbox.py which calls os.setsid() so
#     the suite runs in its own session — os.killpg(0, ...) targets ONLY our
#     subtree, never escapes to the user's outer CC session.
#  4. The Python wrapper invokes plugin/tests/run-all-inner.sh which holds
#     the actual suite discovery + execution + gates + self-check.
#
# Direct flag pass-through: --quick / --help work as before.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"

# Story 144: OPT-IN serialization (default OFF).
# shellcheck source=../scripts/run-all-lock.sh
[ "${WOW_RUNALL_SERIALIZE:-}" = "1" ] && . "$DIR/../scripts/run-all-lock.sh"

# Story 160: ulimit -u is RLIMIT_NPROC — counts the USER's total procs across
# all processes, not just our subshell. On a dev workstation with multiple
# CC sessions + system daemons, current usage may already exceed naive
# default budgets, so a blind `ulimit -u 500` would make every subsequent
# fork in our suite fail (including legit ones).
#
# Best-effort: only apply the budget if it leaves at least 500 procs of
# headroom over current usage. Otherwise log + skip; the session-leader
# reap + per-test timeout still bound the worst case.
TEST_PROC_BUDGET="${WOW_TEST_PROC_BUDGET:-2000}"
CURRENT_PROCS=$(ps -u "$(whoami)" 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$CURRENT_PROCS" ] && [ "$CURRENT_PROCS" -lt $((TEST_PROC_BUDGET - 500)) ]; then
  ulimit -u "$TEST_PROC_BUDGET" 2>/dev/null || true
else
  echo "[run-all.sh] WOW_TEST_PROC_BUDGET=$TEST_PROC_BUDGET <= current user procs ($CURRENT_PROCS) + 500 headroom; skipping ulimit. setsid + timeout still in effect." >&2
fi

# Story 160: exec into Python sandbox wrapper. os.setsid() makes the wrapper
# its own session leader; os.killpg(0, SIGTERM)+sleep+SIGKILL on exit/signal
# reaps the entire test subtree (no leaked grandchildren survive).
SANDBOX="$DIR/../scripts/run-all-sandbox.py"
INNER="$DIR/run-all-inner.sh"
if [ ! -x "$SANDBOX" ] || [ ! -f "$INNER" ]; then
  echo "[run-all.sh] sandbox or inner runner missing — falling back to direct invocation" >&2
  exec bash "$INNER" "$@"
fi

exec python3 "$SANDBOX" -- bash "$INNER" "$@"
