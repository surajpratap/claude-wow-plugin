#!/usr/bin/env python3
"""manager-monitor.py — long-running idle detector for the WOW team.

Loop every 60 seconds:
  1. If implementations/.nothing_to_do exists → silent (no nudge).
  2. Enumerate live wow-process PIDs (PID-marker file exists + kill -0 OK).
  3. For each live PID in the required set ({manager, senior-developer,
     pair-programmer, tester}), find its most recent row in
     implementations/.activity.jsonl.
  4. If every live required PID's latest row.type ∈ {stop, stop_failure}
     AND there's at least one live required PID → emit all-idle-nudge
     to manager via the claude-wow MCP server's CLI emit mode.

Special flag: --check-predicate runs the predicate once and prints one of:
  "idle" | "busy" | "no-required-agents"
"""
import datetime
import json
import os
import subprocess
import sys
import time

REQUIRED_ROLES = frozenset(["manager", "senior-developer", "pair-programmer", "tester"])
LOOP_INTERVAL = 60
TERMINAL_TYPES = frozenset(["stop", "stop_failure"])


def find_project_root():
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
    raise SystemExit("manager-monitor: cannot resolve project root")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        return False


def live_required_pids(project_root):
    """Return list of (role, pid) for every live wow-process PID in REQUIRED_ROLES."""
    marker_dir = os.path.join(project_root, ".claude", ".session-role-by-claude-pid")
    if not os.path.isdir(marker_dir):
        return []
    out = []
    for fname in os.listdir(marker_dir):
        try:
            pid = int(fname)
        except ValueError:
            continue
        marker_path = os.path.join(marker_dir, fname)
        try:
            with open(marker_path) as f:
                role = f.read().strip()
        except OSError:
            continue
        if role not in REQUIRED_ROLES:
            continue
        if not pid_alive(pid):
            continue
        out.append((role, pid))
    return out


def latest_row_for_pid(project_root, pid):
    """Return the most recent activity-log row dict for the given PID, or None."""
    log_path = os.path.join(project_root, "implementations", ".activity.jsonl")
    if not os.path.isfile(log_path):
        return None
    try:
        with open(log_path) as f:
            lines = f.readlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            row = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if row.get("claude_pid") == pid:
            return row
    return None


def check_predicate(project_root):
    """Return one of: 'idle' | 'busy' | 'no-required-agents'."""
    live = live_required_pids(project_root)
    if not live:
        return "no-required-agents"
    for role, pid in live:
        row = latest_row_for_pid(project_root, pid)
        if row is None:
            return "busy"
        if row.get("type") not in TERMINAL_TYPES:
            return "busy"
    return "idle"


def gather_agent_summary(project_root, live):
    """Build the agents[] payload for the nudge bus event."""
    agents = []
    for role, pid in live:
        row = latest_row_for_pid(project_root, pid) or {}
        agents.append({
            "role": role,
            "claude_pid": pid,
            "last_type": row.get("type", ""),
            "last_text": row.get("text", "")
        })
    return agents


def synthesize_monitor_agent_id():
    """Generate an agent-id matching AGENT_ID_RE: <role>-<14digit-ts>-<6hex>."""
    import secrets
    ts = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%S")
    return f"monitor-{ts}-{secrets.token_hex(3)}"


def emit_nudge(project_root, agents):
    """Shell out to MCP server CLI mode to emit the all-idle-nudge."""
    server_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "mcp", "claude-wow-server", "server.py"
    )
    agent_id = synthesize_monitor_agent_id()
    agent_lines = []
    for a in agents:
        last_text = (a.get("last_text") or "").strip()
        if not last_text:
            last_text = f"(no message — last event was {a.get('last_type', 'unknown')})"
        agent_lines.append(f"  - {a['role']}: {last_text}")
    prompt_text = (
        "There has been no activity from any agent for some time.\n\n"
        "Last message from each agent:\n"
        + "\n".join(agent_lines) + "\n\n"
        "Decide whether to call the `declare_idle` tool to indicate there's no "
        "more work to do right now. When in doubt, double-check with an agent "
        "by messaging them via `bus_emit`."
    )
    payload = {
        "detected_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "agents": agents,
        "prompt": prompt_text,
    }
    cmd = [
        "python3", server_path, "bus_emit",
        "--from", agent_id,
        "--to", "manager-*",
        "--type", "all-idle-nudge",
        "--payload-json", json.dumps(payload)
    ]
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = project_root
    try:
        subprocess.run(cmd, env=env, check=False, capture_output=True, timeout=10)
    except (subprocess.SubprocessError, OSError) as e:
        sys.stderr.write(f"[manager-monitor] emit failed: {e}\n")


def marker_present(project_root):
    return os.path.isfile(os.path.join(project_root, "implementations", ".nothing_to_do"))


def main():
    if "--check-predicate" in sys.argv:
        project_root = find_project_root()
        print(check_predicate(project_root))
        return 0
    project_root = find_project_root()
    sys.stderr.write(f"[manager-monitor] starting, project_root={project_root}, interval={LOOP_INTERVAL}s\n")
    while True:
        try:
            if not marker_present(project_root):
                live = live_required_pids(project_root)
                if live and check_predicate(project_root) == "idle":
                    agents = gather_agent_summary(project_root, live)
                    sys.stderr.write(f"[manager-monitor] all-idle detected, emitting nudge ({len(agents)} agents)\n")
                    emit_nudge(project_root, agents)
        except Exception as e:
            sys.stderr.write(f"[manager-monitor] tick error: {e}\n")
        time.sleep(LOOP_INTERVAL)


if __name__ == "__main__":
    sys.exit(main() or 0)
