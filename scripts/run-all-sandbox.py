#!/usr/bin/env python3
"""Story 160 Layer F — process-group sandbox wrapper for tests/run-all.sh.

Becomes its own session leader via os.setsid(), spawns the inner suite runner
as a subprocess, and installs a fork-based reaper that ALWAYS fires on exit
(clean, errored, or signal). The reaper sends TERM → sleep → KILL to the
whole process group AFTER the wrapper itself has exited and emitted rc — so
leaked grandchildren die without taking down rc propagation.

Why a Python wrapper (not bash `exec setsid`):
- setsid(1) is NOT on stock macOS (Homebrew-only via util-linux).
- nohup does NOT create a new session — it only sets SIGHUP handling.
- bash has no native setsid builtin.
- Python's os.setsid() is stdlib, always available, and Story 144's
  run-all-lock.py already established this exact pattern.

Without session-leader status, os.killpg(0, ...) targets the PARENT shell's
PGID and could kill the user's outer CC session. os.setsid() makes the
wrapper its own session leader by construction.

Why fork-then-exit reaping (not synchronous killpg from atexit):
- killpg(PGID, SIGKILL) targets everyone in our group INCLUDING ourselves
  (we're the leader); SIGKILL cannot be caught or ignored, so we'd die
  before sys.exit(rc) propagates.
- Forking a reaper child that ignores SIGTERM, sleeps briefly, then sends
  TERM/grace/KILL to the group lets us exit cleanly with rc while a
  detached reaper cleans the subtree behind us.

Usage:  run-all-sandbox.py -- <command> [args...]
Env:    WOW_TEST_PROC_BUDGET (consumed by the outer shell's ulimit -u);
        WOW_SANDBOX_GRACE_S  (TERM-to-KILL grace, default 0.5).
"""
import atexit
import json
import os
import signal
import subprocess
import sys
import time


def _find_project_root():
    # Story 183 — mirror idle-monitor.find_project_root (CLAUDE_PROJECT_DIR
    # first, then walk up to the project marker) so the verify-marker lands in
    # the SAME implementations/ the idle-monitor reads. NOT getcwd(): from a
    # worktree cwd that would land the marker where the reader's walk-up
    # wouldn't (writer/reader resolution parity).
    env_root = os.environ.get("CLAUDE_PROJECT_DIR")
    if env_root and os.path.isdir(env_root):
        return env_root
    cwd = os.getcwd()
    for _ in range(8):
        if os.path.isfile(os.path.join(cwd, ".claude-plugin", "plugin.json")):
            return cwd
        if os.path.isdir(os.path.join(cwd, ".git")):
            return cwd
        parent = os.path.dirname(cwd)
        if parent == cwd:
            break
        cwd = parent
    return os.getcwd()


def _verify_marker_path():
    return os.path.join(_find_project_root(), "implementations", ".verify-running",
                        "%d.json" % os.getpid())


def _write_verify_marker():
    # Story 183 — announce "a verify is running" so idle-monitor.check_predicate
    # counts the team busy while this run-all is in flight (precise, lifecycle-
    # tied — no 20-min recent_bg_busy timeout). Best-effort: a verify must never
    # fail because the marker I/O failed.
    try:
        path = _verify_marker_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        # heartbeat_ts is a static start stamp (= started_ts, never refreshed);
        # idle-monitor keys on PID liveness, with heartbeat only a secondary
        # >6h PID-reuse guard.
        data = {"pid": os.getpid(), "role": os.environ.get("WOW_ROLE", ""),
                "started_ts": now, "heartbeat_ts": now}
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.rename(tmp, path)
    except OSError:
        pass


def _remove_verify_marker():
    try:
        os.remove(_verify_marker_path())
    except OSError:
        pass


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--":
        print("Usage: run-all-sandbox.py -- <command> [args...]", file=sys.stderr)
        sys.exit(2)
    cmd = sys.argv[2:]

    # Become session leader. Now PGID == PID of this process.
    # After setsid, os.killpg(0, ...) targets only OUR subtree.
    os.setsid()
    my_pgid = os.getpgrp()
    _write_verify_marker()

    grace = float(os.environ.get("WOW_SANDBOX_GRACE_S", "0.5"))

    def fork_reaper():
        """Fork a detached reaper child that sweeps the process group.
        Survives our exit; ignores SIGTERM on itself so it can complete the
        TERM-grace-KILL sequence even when its own targeting hits the group
        it lives in. Returns immediately in the parent."""
        try:
            r_pid = os.fork()
        except OSError:
            return
        if r_pid != 0:
            return
        try:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        except (ValueError, OSError):
            pass
        time.sleep(0.1)
        try:
            os.killpg(my_pgid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        time.sleep(grace)
        try:
            os.killpg(my_pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        os._exit(0)

    def signal_handler(signum, _frame):
        _remove_verify_marker()  # os._exit below skips atexit, so remove here too
        fork_reaper()
        os._exit(128 + signum)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    atexit.register(fork_reaper)
    atexit.register(_remove_verify_marker)  # LIFO → runs before fork_reaper on normal exit

    try:
        proc = subprocess.Popen(cmd)
        rc = proc.wait()
    except FileNotFoundError as e:
        print(f"[run-all-sandbox] {e}", file=sys.stderr)
        sys.exit(127)

    sys.exit(rc)


if __name__ == "__main__":
    main()
