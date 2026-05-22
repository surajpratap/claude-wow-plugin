#!/usr/bin/env python3
"""Story 144 — run-all serialization lock wrapper.

Acquires an exclusive flock on a repo-keyed lockfile, then runs the given
command (the run-all suite pass) AS A CHILD while holding the lock, and exits
with the child's status.

Why a python wrapper (not bash `exec 9>lock`): a bash-inherited fd is shared
with every suite subprocess, so a SIGKILL'd holder with a lingering orphan
child keeps the lock alive (caught by the real-path regression). Python's
`os.open` fd is NON-inheritable by default (PEP 446), so the suite children
never inherit the lock fd — the lock lifetime is bound to THIS process and
releases the instant it dies (normal exit OR signal). flock(1) is also absent
on stock macOS; fcntl.flock is portable.

Usage:  run-all-lock.py -- <command> [args...]
Env:    WOW_RUNALL_LOCKFILE (override path), WOW_RUNALL_LOCK_TIMEOUT (sec, default 1800).
"""
import fcntl
import hashlib
import os
import subprocess
import sys
import time


def _lockfile_path():
    override = os.environ.get("WOW_RUNALL_LOCKFILE")
    if override:
        return override
    try:
        gcd = subprocess.check_output(
            ["git", "rev-parse", "--git-common-dir"],
            stderr=subprocess.DEVNULL).decode().strip()
        gcd = os.path.realpath(gcd)
    except Exception:
        gcd = os.path.realpath(os.getcwd())
    key = hashlib.sha256(gcd.encode()).hexdigest()[:16]
    return os.path.join(os.environ.get("TMPDIR", "/tmp"), "wow-run-all-%s.lock" % key)


def main(argv):
    if not argv or argv[0] != "--" or len(argv) < 2:
        sys.stderr.write("usage: run-all-lock.py -- <command> [args...]\n")
        return 2
    cmd = argv[1:]
    lockfile = _lockfile_path()
    timeout = float(os.environ.get("WOW_RUNALL_LOCK_TIMEOUT", "1800"))

    # os.open fd is non-inheritable by default (PEP 446) → suite children
    # never co-hold the lock; releases the instant THIS process dies.
    fd = os.open(lockfile, os.O_CREAT | os.O_RDWR, 0o644)
    deadline = time.time() + timeout
    notified = False
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > deadline:
                sys.stderr.write(
                    "run-all-lock: TIMEOUT after %ss waiting for %s — a run-all "
                    "may be hung. Set WOW_RUNALL_LOCK_TIMEOUT to adjust.\n"
                    % (timeout, lockfile))
                return 1
            if not notified:
                sys.stderr.write(
                    "run-all-lock: another run-all holds the lock; waiting (%s)…\n"
                    % lockfile)
                notified = True
            time.sleep(0.5)

    # Run the suite pass as a child WHILE holding (fd is non-inheritable).
    try:
        return subprocess.call(cmd)
    finally:
        # explicit release on normal return; the kernel also releases on death.
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
