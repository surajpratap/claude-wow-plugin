#!/usr/bin/env python3
"""Story 154 — Monitor truncation wrapper.

Reads stdin line-by-line. For every line:
  1. Append the FULL line, untruncated, to
     ${ROOT}/implementations/.monitor-events/<purpose>/<task-id>.jsonl,
     fcntl.flock-serialized + fsync'd.
  2. Emit ONE short pointer line on stdout naming the path, the
     1-indexed line number, and the MCP tool CC must call to load the
     full event:

       [monitor:<purpose>] event #<N> at <relative-path>. Call
       `monitor_event_read` (mcp__claude-wow__monitor_event_read) with
       {event_file: "<relative-path>", line: <N>} to load the full text.

CC's Monitor surfaces only the pointer (well under the ~500-char
truncation budget); CC parses the pointer and calls the named tool to
fetch the raw line text.

Why a Python wrapper (not bash `flock`): macOS lacks flock(1). Python's
fcntl.flock is portable and matches the project's established
serialization pattern (see plugin/scripts/run-all-lock.py).
"""

import argparse
import fcntl
import os
import pathlib
import subprocess
import sys
import time


def _project_root():
    """Resolve the WOW project root (git toplevel, or cwd fallback).

    Honors WOW_ROOT override for test fixtures.
    """
    override = os.environ.get("WOW_ROOT")
    if override:
        return os.path.realpath(override)
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return os.path.realpath(out)
    except Exception:
        return os.path.realpath(os.getcwd())


def _resolve_task_id(cli_arg):
    """Pick the wrapper's task-id per the cascade:
       1. --task-id CLI arg if provided
       2. $WOW_MONITOR_TASK_ID env var if set
       3. self-generated from $$-<unix-ts> (the documented default)
    """
    if cli_arg:
        return cli_arg
    env_val = os.environ.get("WOW_MONITOR_TASK_ID")
    if env_val:
        return env_val
    return "{}-{}".format(os.getpid(), int(time.time()))


def main():
    parser = argparse.ArgumentParser(
        description="Wrap a Monitor source: persist full events to disk, emit short pointer.",
    )
    parser.add_argument("--purpose", required=True,
                        help="bus-tail | github-bridge | idle-monitor | slack-bridge-spawn | slack-events-feed")
    parser.add_argument("--task-id", default=None,
                        help="CC Monitor task id; defaults to env or self-generated.")
    args = parser.parse_args()

    purpose = args.purpose
    task_id = _resolve_task_id(args.task_id)

    root = _project_root()
    events_dir = pathlib.Path(root) / "implementations" / ".monitor-events" / purpose
    events_dir.mkdir(parents=True, exist_ok=True)
    events_file = events_dir / "{}.jsonl".format(task_id)
    relative_path = events_file.relative_to(root)

    for line in sys.stdin:
        # Preserve the original line bytes verbatim; sys.stdin gives us
        # a trailing \n if the source line had one. Empty lines (a bare
        # \n) still get a pointer — silent drop would hide signal.
        if line == "":
            continue

        appended_line = line if line.endswith("\n") else line + "\n"

        # Open append-mode + exclusive flock; release immediately after
        # the write+fsync. Python's os.open fd is non-inheritable by
        # default (PEP 446), so any child the source spawns will not
        # inherit the lock.
        fd = os.open(str(events_file), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                os.write(fd, appended_line.encode("utf-8", errors="replace"))
                os.fsync(fd)
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

        # Compute the line number AFTER the append. Cheap (file is local,
        # appending writer is single-process per task-id). For high-volume
        # purposes, this could be tracked in-process — out of scope for v1.
        with open(str(events_file), "rb") as f:
            n_lines = sum(1 for _ in f)

        pointer = (
            "[monitor:{purpose}] event #{n} at {path}. "
            "Call `monitor_event_read` (mcp__claude-wow__monitor_event_read) "
            "with {{event_file: \"{path}\", line: {n}}} to load the full text."
        ).format(purpose=purpose, n=n_lines, path=relative_path)

        sys.stdout.write(pointer + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
