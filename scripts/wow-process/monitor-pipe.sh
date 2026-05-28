#!/usr/bin/env bash
# monitor-pipe.sh — thin bash launcher for monitor-pipe.py (Story 154).
#
# Every Monitor source pipes its raw stdout through this script. The
# Python implementation appends the full line to a per-purpose JSONL
# file and emits a short pointer on stdout (≤500-char) that names the
# MCP tool CC must call (monitor_event_read) to load the untruncated
# event.
#
# Args (forwarded to monitor-pipe.py):
#   --purpose <bus-tail|github-bridge|idle-monitor|slack-bridge-spawn|slack-events-feed>
#   --task-id <id>   (optional; defaults to $WOW_MONITOR_TASK_ID or
#                    self-generated $$-<unix-ts> per the wrapper's
#                    documented MVP behavior)
#
# Why python: macOS lacks flock(1); the Python fcntl.flock pattern is
# the project's established portable serialization primitive (see
# plugin/scripts/run-all-lock.py).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "${SCRIPT_DIR}/monitor-pipe.py" "$@"
