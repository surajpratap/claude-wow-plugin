#!/usr/bin/env bash
# Story 144 — run-all serialization lock (SOURCE this near the TOP of run-all.sh,
# BEFORE arg-parse, so the re-exec preserves the original "$@").
#
# ROOT-CAUSE DOC (so the 4-sprint misdiagnosis does not recur): the cross-sprint
# verification flakes were RESOURCE/OOM contention from concurrent `run-all`
# (many python bridge subprocesses + startup-timing-sensitive suites racing
# under load). They were NOT a port-47823 collision (the hardcoded-47823 tests
# are POLLING mode; run.py binds a listener ONLY in webhook mode → 47823 is
# never bound) and NOT a github-bridge-cursor.sh test bug (instrumented 0/15
# nonzero under heavy load; deterministic $FAIL-only exit). The fix is to
# SERIALIZE concurrent run-all so they don't contend — which is why the team's
# manual run-all-slot practice worked. This mechanizes it.
#
# MECHANISM: re-exec self under run-all-lock.py — a python wrapper that holds an
# exclusive flock on a repo-keyed lockfile + runs THIS run-all (the locked pass)
# as its child. Python's lock fd is NON-inheritable (PEP 446), so suite
# subprocesses never co-hold it and the lock lifetime is bound to the wrapper:
# it releases the instant the wrapper dies (normal exit OR signal) — no
# held-slot-deadlock, even on SIGKILL. (A bash `exec 9>` fd would be inherited
# by every suite child, so a killed holder with a lingering orphan keeps the
# lock — the real-path regression caught exactly that.) flock(1) is absent on
# stock macOS; fcntl.flock is portable.

if [ -z "${WOW_RUNALL_LOCKED:-}" ]; then
  # Not yet under the lock. --help/-h must not acquire (or block on) the lock.
  case "${1:-}" in
    --help|-h) : ;;
    *)
      _wow_lockpy="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-all-lock.py"
      if [ -f "$_wow_lockpy" ] && command -v python3 >/dev/null 2>&1; then
        exec python3 "$_wow_lockpy" -- env WOW_RUNALL_LOCKED=1 bash "$0" "$@"
      fi
      echo "run-all-lock: python3 or wrapper missing; proceeding UNLOCKED" >&2
      ;;
  esac
else
  # We ARE the locked pass (the wrapper's child). Test-only hooks for the
  # real-path regression: hold after acquiring, and/or exit right
  # after acquiring so a 2nd real run-all can be observed BLOCKING without
  # running the full suite. Never set in normal runs.
  if [ -n "${WOW_RUNALL_LOCK_HOLD_SECONDS:-}" ]; then
    sleep "$WOW_RUNALL_LOCK_HOLD_SECONDS"
  fi
  if [ -n "${WOW_RUNALL_ACQUIRE_ONLY:-}" ]; then
    echo "run-all: WOW_RUNALL_ACQUIRE_ONLY — acquired lock, exiting (test mode)" >&2
    exit 0
  fi
fi
