#!/usr/bin/env python3
"""idle-limit-monitor (idle + limit) — long-running monitor for the WOW team.

Filename kept as idle-monitor.{py,sh} (52-file reference blast-radius — Story
172 keeps the name, renames only the conceptual label). Two additive codepaths
share the same 60s loop; the idle predicate/wake logic below is UNCHANGED.

IDLE codepath — loop every 60 seconds:
  1. If implementations/.nothing_to_do exists → silent (no nudge).
  2. Enumerate live wow-process PIDs (PID-marker file exists + kill -0 OK).
  3. For each live PID in the required set ({manager, senior-developer,
     pair-programmer, tester}), find its most recent row in
     implementations/.activity.jsonl. A live PID with ZERO rows is
     foreign/stale-marker — skipped, not counted as busy.
  4. If every participating PID's (live + ≥1 activity row) latest row.type
     ∈ {stop, stop_failure} AND no participating PID has an outstanding
     bg-spawn in its current stop-episode (a peer stop'd while awaiting
     backgrounded work is not idle) AND there's at least one
     participating PID → print one JSONL all-idle-nudge line to
     stdout (CC forwards to M as a Monitor-task notification).

LIMIT codepath (Story 172, additive; runs every tick OUTSIDE the
.nothing_to_do guard) — `_check_usage_limits()` polls the wrapper-written
usage state file and, on the 5h window crossing >=98, bus-emits ONE
`usage-limit-pause` directive (peers halt; M exempt). The DAEMON itself
bus-emits the time-based `usage-limit-reset` once the 5h window has reset.
A 7d window >=99 bus-emits a `usage-limit-7d-escalate` directive addressed
`to: manager-*` (payload.directive == "escalate"; M acts → human; NO peer pause).

Special flag: --check-predicate runs the predicate once and prints one of:
  "idle" | "busy" | "no-required-agents"
"""
import datetime
import json
import os
import subprocess
import sys
import time
import uuid

REQUIRED_ROLES = frozenset(["manager", "senior-developer", "pair-programmer", "tester"])
LOOP_INTERVAL = 60
TERMINAL_TYPES = frozenset(["stop", "stop_failure"])
# Story 111 — per-role truly-idle wake. A peer goes "truly-idle" when its
# latest activity row is terminal AND older than PER_ROLE_IDLE_SECONDS.
# Idempotency state file records the last wake ts per agent_id; don't re-wake
# until PER_ROLE_REWAKE_SECONDS elapse OR the peer emits new activity (the
# stale wake-ts gets overwritten on next firing).
PER_ROLE_IDLE_SECONDS = 600
PER_ROLE_REWAKE_SECONDS = 1800
LAST_WAKE_REL_PATH = "implementations/.wow-process/idle-monitor-last-wake.json"
NON_M_REQUIRED_ROLES = frozenset(["senior-developer", "pair-programmer", "tester"])


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
    raise SystemExit("idle-monitor: cannot resolve project root")


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


BG_SPAWN_TYPE = "bg-spawn"
# Derived from TERMINAL_TYPES so a future change there tracks through.
EPISODE_BOUNDARY_TYPES = TERMINAL_TYPES | frozenset(["session_start"])


def rows_for_pid(project_root, pid):
    """All activity-log rows for a PID, oldest->newest."""
    log_path = os.path.join(project_root, "implementations", ".activity.jsonl")
    rows = []
    if not os.path.isfile(log_path):
        return rows
    try:
        with open(log_path) as f:
            lines = f.readlines()
    except OSError:
        return rows
    for line in lines:
        try:
            row = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if row.get("claude_pid") == pid:
            rows.append(row)
    return rows


# Story 143: a bg run can outlive the stop-episode that spawned it (the peer
# wakes for an unrelated reason, works, stop's again — the bg-spawn now sits in
# a PRIOR episode). Story-098's current-episode-only check then read idle while
# the bg was still running, firing all-idle-nudge every 60s. Fix: count busy
# from the most-recent bg-spawn across ALL episodes, time-bounded so a stale/
# finished bg eventually expires -> idle-monitor recovers (the property M relies
# on). The bg-spawn row records only claude_pid (PreToolUse fires pre-spawn),
# not the bg child PID, so this is a bounded time heuristic; precise per-PID
# liveness is the future upgrade (backlog 181). A finished-but-unresumed bg
# stays "false-busy" only until the cap — accepted + bounded.
BG_BUSY_MAX_AGE_SECONDS = int(os.environ.get("WOW_BG_BUSY_MAX_AGE_SECONDS", "1200"))
SKEW_TOLERANCE_SECONDS = 120  # ignore bg-spawn rows this far ahead of now (clock skew)


def now_epoch():
    """Current epoch seconds; overridable via WOW_IDLE_NOW_EPOCH for deterministic tests."""
    override = os.environ.get("WOW_IDLE_NOW_EPOCH")
    if override:
        try:
            return float(override)
        except ValueError:
            pass
    return time.time()


def recent_bg_busy(rows, now):
    """True if the most-recent bg-spawn (ANY episode) is within the busy window.

    `rows` oldest->newest. Scans all rows for the latest bg-spawn, ignores a row
    whose ts is more than SKEW_TOLERANCE_SECONDS ahead of `now` (clock skew),
    and returns busy iff that spawn's age is within BG_BUSY_MAX_AGE_SECONDS.
    Replaces Story-098's current-episode-only check so a bg-spawn in a PRIOR
    episode still counts.
    """
    latest = None
    for row in rows:
        if row.get("type") != BG_SPAWN_TYPE:
            continue
        ep = parse_iso_ts(row.get("ts"))
        if ep is None:
            continue
        if latest is None or ep > latest:
            latest = ep
    if latest is None:
        return False
    age = now - latest
    if age < -SKEW_TOLERANCE_SECONDS:
        return False  # bg-spawn ts is in the future (clock skew) — don't count busy
    return age <= BG_BUSY_MAX_AGE_SECONDS


def check_predicate(project_root):
    """Return one of: 'idle' | 'busy' | 'no-required-agents'."""
    live = live_required_pids(project_root)
    if not live:
        return "no-required-agents"
    now = now_epoch()
    participating = 0
    for role, pid in live:
        rows = rows_for_pid(project_root, pid)
        if not rows:
            # Story 110: a live PID with a project-local marker but zero
            # activity rows is foreign/stale (a real participant always
            # logs >=1 row — session_start at boot). Skip it; do not
            # treat as "busy", which would poison the predicate forever.
            continue
        participating += 1
        if rows[-1].get("type") not in TERMINAL_TYPES:
            return "busy"
        if recent_bg_busy(rows, now):
            return "busy"  # stop'd, but a bg run is still within the busy window
    if participating == 0:
        # All live PIDs were foreign/stale-marker no-rows. No real cohort here.
        return "no-required-agents"
    return "idle"


def gather_agent_summary(project_root, live):
    """Build the agents[] payload for the nudge event.

    Story 129: filter no-rows PIDs the same way check_predicate does — a
    live PID with zero activity rows is foreign/stale-marker and would
    otherwise leak as a ghost entry (empty last_type / last_text) in the
    all-idle-nudge payload.
    """
    agents = []
    for role, pid in live:
        row = latest_row_for_pid(project_root, pid)
        if not row:
            continue
        agents.append({
            "role": role,
            "claude_pid": pid,
            "last_type": row.get("type", ""),
            "last_text": row.get("text", "")
        })
    return agents


def parse_iso_ts(s):
    """Parse 'YYYY-MM-DDTHH:MM:SSZ' to epoch-seconds, or None on bad input."""
    if not isinstance(s, str):
        return None
    # UTC-aware; handle fractional seconds / explicit offset via fromisoformat
    # (the strptime form below only handles whole-second 'Z').
    try:
        return int(datetime.datetime.fromisoformat(
            s.replace("Z", "+00:00")).timestamp())
    except (ValueError, TypeError):
        pass
    try:
        return int(datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
                   .replace(tzinfo=datetime.timezone.utc).timestamp())
    except (ValueError, TypeError):
        return None


def lookup_agent_id_for_pid(project_root, pid):
    """Return the agent_id whose .agents/<id>.json carries claude_pid == pid.

    Tracker files SD/PP/T/S create at session-start contain a `claude_pid`
    field. If multiple match (drift), prefer the most recent `last_line`.
    """
    agents_dir = os.path.join(project_root, "implementations", ".agents")
    if not os.path.isdir(agents_dir):
        return None
    best_id = None
    best_last_line = -1
    try:
        names = os.listdir(agents_dir)
    except OSError:
        return None
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(agents_dir, name)
        try:
            with open(path) as f:
                tracker = json.load(f)
        except (OSError, json.JSONDecodeError, ValueError):
            continue
        if not isinstance(tracker, dict):
            continue
        if tracker.get("claude_pid") != pid:
            continue
        last_line = tracker.get("last_line", 0) or 0
        if last_line > best_last_line:
            best_last_line = last_line
            best_id = name[:-5]
    return best_id


def load_last_wake_state(project_root):
    """Read the per-agent last-wake-ts state file; return dict or {}."""
    path = os.path.join(project_root, LAST_WAKE_REL_PATH)
    if not os.path.isfile(path):
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_last_wake_state(project_root, state):
    """Atomic write of the last-wake-ts state file."""
    path = os.path.join(project_root, LAST_WAKE_REL_PATH)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.rename(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def emit_per_role_wakes(project_root, live, now_ts):
    """Story 111 — emit one `wake` per truly-idle non-M peer.

    For each non-M peer in `live`: skip unless latest activity row is
    terminal AND older than PER_ROLE_IDLE_SECONDS. Idempotency: skip if
    state file shows this agent_id was waked within PER_ROLE_REWAKE_SECONDS.
    On emit, append/overwrite the state file entry. One stdout line per
    qualifying peer.
    """
    state = load_last_wake_state(project_root)
    fired = []
    for role, pid in live:
        if role not in NON_M_REQUIRED_ROLES:
            continue
        row = latest_row_for_pid(project_root, pid)
        if not row:
            continue
        if row.get("type") not in TERMINAL_TYPES:
            continue
        row_ts = parse_iso_ts(row.get("ts"))
        if row_ts is None or (now_ts - row_ts) < PER_ROLE_IDLE_SECONDS:
            continue
        agent_id = lookup_agent_id_for_pid(project_root, pid)
        if agent_id is None:
            continue
        last_wake_ts = state.get(agent_id, 0)
        if isinstance(last_wake_ts, str):
            last_wake_ts = parse_iso_ts(last_wake_ts) or 0
        if (now_ts - last_wake_ts) < PER_ROLE_REWAKE_SECONDS:
            continue
        idle_seconds = now_ts - row_ts
        event = {
            "ts": datetime.datetime.utcfromtimestamp(now_ts)
                  .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "from": f"idle-monitor-{os.getpid()}",
            "to": agent_id,
            "type": "wake",
            "payload": {
                "agent_id": agent_id,
                "role": role,
                "idle_seconds": idle_seconds,
                "reason": "truly-idle nudge from idle-monitor",
            },
        }
        try:
            print(json.dumps(event), flush=True)
        except BrokenPipeError:
            sys.exit(0)
        state[agent_id] = now_ts
        fired.append(agent_id)
    if fired:
        save_last_wake_state(project_root, state)
    return fired


def truly_idle_status(project_root):
    """Story 181 — per-role confirmed-idle status for the all-idle-nudge payload
    (role + bool + ts only; M loads .activity.jsonl details only when deciding).
    Stays well under the ~500-word pipe cap."""
    path = os.path.join(project_root, "implementations", ".truly-idle.json")
    data = {}
    if os.path.isfile(path):
        try:
            with open(path) as f:
                data = json.load(f) or {}
        except (OSError, ValueError):
            data = {}
    if not isinstance(data, dict):
        data = {}
    out = []
    for role in ("senior-developer", "pair-programmer", "tester"):
        entry = data.get(role)
        if not isinstance(entry, dict):
            entry = {}
        out.append({"role": role, "confirmed": bool(entry.get("idle")), "ts": entry.get("ts")})
    return out


def emit_idle_event(agents, project_root):
    """Print one JSONL all-idle-nudge line to stdout."""
    now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    agent_lines = []
    for a in agents:
        last_text = (a.get("last_text") or "").strip()
        if not last_text:
            last_text = f"(no message — last event was {a.get('last_type', 'unknown')})"
        agent_lines.append(f"  - {a['role']}: {last_text}")
    prompt_text = (
        "There has been no activity from any agent for some time.\n\n"
        f"Current time: {now}\n\n"
        "Last message from each agent:\n"
        + "\n".join(agent_lines) + "\n\n"
        "Decide whether to call the `declare_idle` tool to indicate there's no "
        "more work to do right now. When in doubt, double-check with an agent "
        "by messaging them via `bus_emit`.\n\n"
        "Please do not ignore this situation. Agents can appear idle when no "
        "activity is being recorded from them while they have actually spawned "
        "sub-agents to do work — it is always worth checking in with the agents "
        "via the `bus_emit` message-bus tool. If you determine all agents are "
        "genuinely idle because there is no work, you MUST call the `declare_idle` "
        "tool so this idle check-in stops firing — otherwise it triggers every "
        "minute and wastes tokens."
    )
    event = {
        "ts": now,
        "from": f"idle-monitor-{os.getpid()}",
        "to": "manager-*",
        "type": "all-idle-nudge",
        "payload": {
            "detected_at": now,
            "agents": agents,
            "idle_status": truly_idle_status(project_root),
            "prompt": prompt_text,
        },
    }
    try:
        print(json.dumps(event), flush=True)
    except BrokenPipeError:
        sys.exit(0)


def marker_present(project_root):
    return os.path.isfile(os.path.join(project_root, "implementations", ".nothing_to_do"))


# ---------------------------------------------------------------------------
# Story 172 — opt-in usage auto-pause (additive limit codepath).
# ---------------------------------------------------------------------------
FIVE_HOUR_PAUSE_THRESHOLD = 98
SEVEN_DAY_ESCALATE_THRESHOLD = 99
# Small buffer past resets_at before the daemon emits resume — the state file
# is stale at >=98 until the first post-reset render, so we lead slightly to
# avoid a thrash window. The natural recheck-loop re-pauses if still capped.
RESET_BUFFER_SECONDS = int(os.environ.get("WOW_USAGE_RESET_BUFFER_SECONDS", "0"))
USAGE_PAUSE_MARKER_REL = "implementations/.wow-process/usage-limit-pause-marker.json"
USAGE_STATE_DEFAULT_REL = "implementations/.wow-process/five-hour-usage.json"


def _truthy(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def usage_autopause_enabled(project_root):
    """AC1 opt-in gate. The limit codepath acts ONLY when the human opted in.
    Source precedence: WOW_USAGE_AUTOPAUSE env (the test override + explicit
    operator escape hatch) ELSE M's tracker `usage_autopause` flag in any
    implementations/.agents/<id>.json. Default (env unset AND no tracker flag) =
    FALSE → the caller returns early, emitting nothing.
    """
    env = os.environ.get("WOW_USAGE_AUTOPAUSE")
    if env is not None:
        return _truthy(env)
    agents_dir = os.path.join(project_root, "implementations", ".agents")
    try:
        names = os.listdir(agents_dir)
    except OSError:
        return False
    for name in names:
        if not name.endswith(".json"):
            continue
        tracker = _load_json_file(os.path.join(agents_dir, name))
        if isinstance(tracker, dict) and tracker.get("usage_autopause") is True:
            return True
    return False


def usage_state_path(project_root):
    override = os.environ.get("WOW_USAGE_STATE_FILE")
    if override:
        return override
    return os.path.join(project_root, USAGE_STATE_DEFAULT_REL)


def usage_pause_marker_path(project_root):
    return os.path.join(project_root, USAGE_PAUSE_MARKER_REL)


def _load_json_file(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _write_json_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.rename(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def limit_monitor_agent_id():
    """A from-ID for the limit codepath. DISTINCT `limit-monitor-` prefix (NOT
    `idle-monitor-`, which manager.md routes to M's private idle-event handler
    BEFORE type-handling — that would misclassify the directive). 6 LOWERCASE
    hex so it passes server.py's AGENT_ID_RE (`^[a-z-]+-[0-9]{8}T[0-9]{6}-[a-f0-9]{6}$`).
    """
    ts = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%S")
    suffix = uuid.uuid4().hex[:6]
    return f"limit-monitor-{ts}-{suffix}"


def _server_py_path():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "mcp", "claude-wow-server", "server.py"))


def emit_limit_directive(msg_type, payload, to="*"):
    """Bus-emit a bounded directive via the sanctioned MCP CLI path (NOT the
    M-private print() path — the consumer must see it directly on the bus;
    CENTERPIECE). `to` defaults to `*` (broadcast pause/resume to peers); the
    7d escalate addresses `manager-*` (M-private — only M acts; peers ignore
    escalate, FINDING-47). The subprocess INHERITS this process's env
    (CLAUDE_PROJECT_DIR/WOW_ROOT) so it resolves the same bus this monitor was
    launched against (174 discipline).
    """
    server = _server_py_path()
    if not os.path.isfile(server):
        sys.stderr.write(f"[idle-limit-monitor] server.py not found at {server}; cannot emit {msg_type}\n")
        return False
    cmd = [
        sys.executable, server, "bus_emit",
        "--from", limit_monitor_agent_id(),
        "--to", to,
        "--type", msg_type,
        "--payload-json", json.dumps(payload, separators=(",", ":")),
    ]
    try:
        proc = subprocess.run(cmd, env=os.environ.copy(),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        sys.stderr.write(f"[idle-limit-monitor] emit {msg_type} failed: {e}\n")
        return False
    if proc.returncode != 0:
        sys.stderr.write(f"[idle-limit-monitor] emit {msg_type} rc={proc.returncode}: "
                         f"{proc.stderr.decode('utf-8', 'replace')}\n")
        return False
    return True


def emit_seven_day_escalate(seven_day):
    """7d>=99 → M-PRIVATE escalate, addressed `to: manager-*` (peers NOT
    auto-halted on 7d, #140). FINDING-47: emitted as a BUS directive
    (payload.directive == "escalate", the closed enum's third value) via the
    sanctioned bus_emit path — NOT an off-bus print() that fell through M's
    Monitor dispatch inert. M's role-asymmetric directive arm acts on `escalate`
    (escalate to the human); peers ignore it. The `limit-monitor-` producer
    prefix is kept (NOT `idle-monitor-`, which M routes to its private idle-event
    handler before type-handling — that would misclassify the directive).
    """
    payload = {
        "directive": "escalate",
        "window": "seven_day",
        "used_percentage": seven_day.get("used_percentage"),
        "resets_at": seven_day.get("resets_at"),
        "prompt": (
            "7-day usage window is at or above the escalation threshold. "
            "The team is NOT auto-halted (the 7d reset is days away). "
            "Escalate to the human for a decision (AskUserQuestion / Slack); any "
            "pause that follows is the human's post-escalation choice."
        ),
    }
    # --- SEVEN-DAY-ESCALATE-EMIT (usage-limit-7d-escalate.patch reverts this to no emit) ---
    return emit_limit_directive("usage-limit-7d-escalate", payload, to="manager-*")


def _check_usage_limits(project_root):
    """Story 172 limit codepath (additive). Gated by the presence of the
    wrapper-written usage state file — absent → no-op (opt-out / not yet
    rendered). Drives the 5h pause/time-resume bus directives + the 7d
    M-private escalate. Idempotent via the pause-marker.
    """
    # --- USAGE-OPTIN-GATE-START (opt-in-gate.patch reverts this block) ---
    if not usage_autopause_enabled(project_root):
        return
    # --- USAGE-OPTIN-GATE-END ---
    state = _load_json_file(usage_state_path(project_root))
    if state is None:
        return
    now = now_epoch()
    marker_path = usage_pause_marker_path(project_root)
    marker = _load_json_file(marker_path)

    five = state.get("five_hour") or {}
    seven = state.get("seven_day") or {}

    five_pct = five.get("used_percentage")
    five_resets = five.get("resets_at")

    # 5h pause-detect — no marker active AND >= threshold → ONE pause.
    if marker is None and isinstance(five_pct, (int, float)) \
            and five_pct >= FIVE_HOUR_PAUSE_THRESHOLD:
        payload = {"directive": "pause", "window": "five_hour", "resets_at": five_resets}
        if emit_limit_directive("usage-limit-pause", payload):
            _write_json_atomic(marker_path, {
                "window": "five_hour",
                "resets_at": five_resets,
                "fired_ts": now,
            })
            marker = {"window": "five_hour", "resets_at": five_resets, "fired_ts": now}

    # 5h time-based resume — marker active AND now >= resets_at + buffer →
    # ONE resume (daemon-emitted, NEVER %-gated); clear the marker.
    if marker is not None:
        resets_at = marker.get("resets_at")
        resets_epoch = parse_iso_ts(resets_at)
        if resets_epoch is not None and now >= resets_epoch + RESET_BUFFER_SECONDS:
            if emit_limit_directive("usage-limit-reset", {"directive": "resume"}):
                try:
                    os.unlink(marker_path)
                except OSError:
                    pass

    # 7d escalate — M-private, NO peer pause.
    seven_pct = seven.get("used_percentage")
    if isinstance(seven_pct, (int, float)) and seven_pct >= SEVEN_DAY_ESCALATE_THRESHOLD:
        emit_seven_day_escalate(seven)


def main():
    if "--check-predicate" in sys.argv:
        project_root = find_project_root()
        print(check_predicate(project_root))
        return 0
    project_root = find_project_root()
    sys.stderr.write(f"[idle-monitor] starting, project_root={project_root}, interval={LOOP_INTERVAL}s\n")
    while True:
        try:
            # Story 172 limit codepath — runs every tick, OUTSIDE the
            # .nothing_to_do guard (the team can be declared-idle and still need
            # the 5h pause/resume + 7d escalate). Idle predicate/wake UNTOUCHED.
            _check_usage_limits(project_root)
            if not marker_present(project_root):
                live = live_required_pids(project_root)
                if live:
                    # Story 111: per-role truly-idle wake — emit BEFORE the
                    # all-idle check, since the two paths use different
                    # predicates (any non-M peer terminal+stale vs ALL peers
                    # idle). Both can fire on the same tick.
                    now_ts = int(time.time())
                    emit_per_role_wakes(project_root, live, now_ts)
                if live and check_predicate(project_root) == "idle":
                    agents = gather_agent_summary(project_root, live)
                    sys.stderr.write(f"[idle-monitor] all-idle detected, emitting event ({len(agents)} agents)\n")
                    emit_idle_event(agents, project_root)
        except Exception as e:
            sys.stderr.write(f"[idle-monitor] tick error: {e}\n")
        time.sleep(LOOP_INTERVAL)


if __name__ == "__main__":
    sys.exit(main() or 0)
