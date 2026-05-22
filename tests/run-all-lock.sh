#!/usr/bin/env bash
# Story 144 — the run-all serialization lock, exercised through the REAL
# run-all.sh path (PP REQUIRED 2: a standalone helper-holds-and-sleeps proxy
# would pass even if run-all.sh integrated the lock as an inert subprocess).
# Drives run-all.sh with the test-only WOW_RUNALL_ACQUIRE_ONLY / _HOLD_SECONDS
# hooks + an isolated WOW_RUNALL_LOCKFILE, so it's deterministic + fast.

set -u
PASS=0; FAIL=0; FAILED=()
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); FAILED+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNALL="$SCRIPT_DIR/run-all.sh"
[ -f "$RUNALL" ] || { echo "run-all-lock: SKIP — run-all.sh not found"; exit 0; }

# This test drives REAL run-all.sh sub-invocations that must each go through the
# lock re-exec. (1) When THIS test runs INSIDE a run-all (which, when serializing,
# sets WOW_RUNALL_LOCKED=1), that var is inherited and would make our sub-run-alls
# skip the lock — so unset it + the hooks for our children. (2) The lock is now
# OPT-IN (default off, Story 144 per the human), so our sub-run-alls must opt IN
# (WOW_RUNALL_SERIALIZE=1) to exercise the lock at all. Both caught by running the
# regression inside the full suite — the realest path.
unset WOW_RUNALL_LOCKED WOW_RUNALL_ACQUIRE_ONLY WOW_RUNALL_LOCK_HOLD_SECONDS WOW_RUNALL_LOCKFILE WOW_RUNALL_LOCK_TIMEOUT
export WOW_RUNALL_SERIALIZE=1   # opt our sub-run-alls into the (default-off) lock

LOCK=$(mktemp -u)   # isolated lockfile path (per PP MINOR — explicit override)
now(){ python3 -c 'import time;print(time.time())'; }

# --- 1. a 2nd REAL run-all BLOCKS until the 1st releases (serialization) ------
( WOW_RUNALL_LOCKFILE="$LOCK" WOW_RUNALL_ACQUIRE_ONLY=1 WOW_RUNALL_LOCK_HOLD_SECONDS=3 \
    bash "$RUNALL" >/dev/null 2>&1 ) &
A=$!
sleep 0.8   # let A acquire + enter its hold
t0=$(now)
WOW_RUNALL_LOCKFILE="$LOCK" WOW_RUNALL_ACQUIRE_ONLY=1 bash "$RUNALL" >/dev/null 2>&1
waited=$(python3 -c "print($(now) - $t0)")
wait "$A" 2>/dev/null
# A held ~3s, B started at +0.8s → B should have waited ~1.8s+ (clearly blocked)
if python3 -c "import sys; sys.exit(0 if $waited > 1.2 else 1)"; then ok; else
  bad "2nd real run-all did NOT block (waited ${waited}s — lock inert / not held for duration?)"; fi

# --- 2. lock AUTO-RELEASES when the holder is KILLED (no stale deadlock) ------
( WOW_RUNALL_LOCKFILE="$LOCK" WOW_RUNALL_ACQUIRE_ONLY=1 WOW_RUNALL_LOCK_HOLD_SECONDS=30 \
    bash "$RUNALL" >/dev/null 2>&1 ) &
H=$!
sleep 0.8
kill -KILL "$H" 2>/dev/null; wait "$H" 2>/dev/null
t0=$(now)
WOW_RUNALL_LOCKFILE="$LOCK" WOW_RUNALL_ACQUIRE_ONLY=1 bash "$RUNALL" >/dev/null 2>&1
rel=$(python3 -c "print($(now) - $t0)")
if python3 -c "import sys; sys.exit(0 if $rel < 1.5 else 1)"; then ok; else
  bad "lock did NOT auto-release on holder kill (2nd waited ${rel}s — stale-lock deadlock)"; fi

# --- 3. acquire-TIMEOUT fires (a LIVE hung holder must not block forever) -----
( WOW_RUNALL_LOCKFILE="$LOCK" WOW_RUNALL_ACQUIRE_ONLY=1 WOW_RUNALL_LOCK_HOLD_SECONDS=10 \
    bash "$RUNALL" >/dev/null 2>&1 ) &
G=$!
sleep 0.8
err=$(WOW_RUNALL_LOCKFILE="$LOCK" WOW_RUNALL_ACQUIRE_ONLY=1 WOW_RUNALL_LOCK_TIMEOUT=1 \
        bash "$RUNALL" 2>&1 >/dev/null)
kill -KILL "$G" 2>/dev/null; wait "$G" 2>/dev/null
if printf '%s' "$err" | grep -qi 'timeout'; then ok; else
  bad "acquire-timeout did not fire / no diagnostic (got: $err)"; fi

rm -f "$LOCK"
echo "run-all-lock: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
