#!/usr/bin/env python3
"""manager-monitor — the manager-side per-minute monitor for the WOW team.

One ~60s loop with two named concerns: `usage_concern()` and `idle_concern()`.
Both surface to M as Monitor-task notifications on this process's stdout.

idle_concern — loop every 60 seconds:
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

usage_concern (runs every tick OUTSIDE the .nothing_to_do guard) — polls the
wrapper-written usage state file and PIPES a usage signal to M on stdout (NOT a
bus directive — M owns the reaction). On the 5h window crossing >= 95 it pipes
ONE `usage-limit` event (M then broadcasts an urgent `pause` with
`kill_subagents:true` + escalates the human). Once the 5h window resets it pipes
`usage-reset` (M broadcasts `resume`). A 7d window >= 99 pipes `usage-escalate`
(M escalates the human; notify-only, NO peer pause). All events carry the
`manager-monitor-<pid>` from-prefix; M dispatches on `type`.

Special flag: --check-predicate runs the predicate once and prints one of:
  "idle" | "busy" | "no-required-agents"
"""
import datetime
import json
import os
import sys
import time

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
LAST_WAKE_REL_PATH = "implementations/.wow-process/manager-monitor-last-wake.json"
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
    raise SystemExit("manager-monitor: cannot resolve project root")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        return False


VERIFY_HEARTBEAT_STALE_SECONDS = 21600  # 6h — far beyond any real verify; a secondary PID-reuse guard


def has_live_verify_marker(project_root):
    """True if any implementations/.verify-running/<pid>.json marker has a live
    PID with a fresh-enough heartbeat. Dead-PID markers are swept (a crashed
    verify that skipped trap-cleanup never false-busies forever). PID liveness
    is the primary signal (closes backlog-181); the heartbeat is a static start
    stamp (written once = started_ts, never refreshed) used only as a secondary
    >6h guard against PID reuse. Best-effort: any I/O error -> not busy."""
    marker_dir = os.path.join(project_root, "implementations", ".verify-running")
    if not os.path.isdir(marker_dir):
        return False
    now = now_epoch()
    found_live = False
    try:
        names = os.listdir(marker_dir)
    except OSError:
        return False
    for fname in names:
        if not fname.endswith(".json"):
            continue
        path = os.path.join(marker_dir, fname)
        try:
            pid = int(fname[:-len(".json")])
        except ValueError:
            continue
        if not pid_alive(pid):
            try:
                os.remove(path)  # stale dead-PID marker -> sweep
            except OSError:
                pass
            continue
        hb = None
        try:
            with open(path) as f:
                hb = parse_iso_ts(json.load(f).get("heartbeat_ts"))
        except (OSError, ValueError):
            hb = None
        if hb is not None and (now - hb) > VERIFY_HEARTBEAT_STALE_SECONDS:
            continue  # live PID but ancient heartbeat -> likely PID reuse; don't count busy
        found_live = True
    return found_live


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
# finished bg eventually expires -> manager-monitor recovers (the property M relies
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
    verify_busy = has_live_verify_marker(project_root)  # also sweeps dead-PID markers
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
    if verify_busy:
        return "busy"  # a run-all verify is in flight — not idle (closes backlog-181 / 238)
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
            "from": f"manager-monitor-{os.getpid()}",
            "to": agent_id,
            "type": "wake",
            "payload": {
                "agent_id": agent_id,
                "role": role,
                "idle_seconds": idle_seconds,
                "reason": "truly-idle nudge from manager-monitor",
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
        "from": f"manager-monitor-{os.getpid()}",
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
FIVE_HOUR_PAUSE_THRESHOLD = 95
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


def pipe_usage_event(msg_type, payload):
    """Story 186 — pipe a usage signal to M on STDOUT (the same Monitor->M
    channel the idle nudges use), NOT a bus directive. M owns the reaction
    (urgent pause + kill_subagents / resume / human escalation); the daemon
    never emits pause/resume itself. `from` carries the manager-monitor-<pid>
    prefix so M's manager_monitor handler dispatches it by `type`.
    """
    now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    event = {
        "ts": now,
        "from": f"manager-monitor-{os.getpid()}",
        "to": "manager-*",
        "type": msg_type,
        "payload": payload,
    }
    try:
        print(json.dumps(event), flush=True)
    except BrokenPipeError:
        sys.exit(0)
    return True


def usage_concern(project_root):
    """Story 186 usage concern (was Story 172's _check_usage_limits). Gated by
    the opt-in + the wrapper-written usage state file. PIPES a usage signal to M
    (usage-limit / usage-reset / usage-escalate) instead of emitting bus
    directives — M owns the urgent-stop reaction. Idempotent via the pause-marker.
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

    # 5h pause-detect — no marker active AND >= threshold → ONE pipe to M.
    # --- USAGE-5H-THRESHOLD (usage-limit-5h-threshold.patch reverts 95->98) ---
    if marker is None and isinstance(five_pct, (int, float)) \
            and five_pct >= FIVE_HOUR_PAUSE_THRESHOLD:
        payload = {
            "kind": "usage-limit",
            "window": "five_hour",
            "used_percentage": five_pct,
            "resets_at": five_resets,
        }
        if pipe_usage_event("usage-limit", payload):
            _write_json_atomic(marker_path, {
                "window": "five_hour",
                "resets_at": five_resets,
                "fired_ts": now,
            })

    # 5h time-based resume — marker active AND now >= resets_at + buffer →
    # ONE usage-reset pipe; clear the marker.
    if marker is not None:
        resets_at = marker.get("resets_at")
        resets_epoch = parse_iso_ts(resets_at)
        if resets_epoch is not None and now >= resets_epoch + RESET_BUFFER_SECONDS:
            if pipe_usage_event("usage-reset", {"kind": "usage-reset", "window": "five_hour"}):
                try:
                    os.unlink(marker_path)
                except OSError:
                    pass

    # 7d escalate — notify-only pipe (M escalates the human; NO peer pause).
    seven_pct = seven.get("used_percentage")
    if isinstance(seven_pct, (int, float)) and seven_pct >= SEVEN_DAY_ESCALATE_THRESHOLD:
        # --- SEVEN-DAY-ESCALATE-PIPE (usage-limit-7d-escalate.patch reverts this to no pipe) ---
        pipe_usage_event("usage-escalate", {
            "kind": "usage-escalate",
            "window": "seven_day",
            "used_percentage": seven_pct,
            "resets_at": seven.get("resets_at"),
        })


def idle_concern(project_root):
    """Story 186 idle concern — the existing all-idle / per-role-wake logic
    (incl. the 183 verify-marker busy gate via marker_present/check_predicate).
    Emits all-idle-nudge + per-role wake on stdout.
    """
    if marker_present(project_root):
        return
    live = live_required_pids(project_root)
    if live:
        # Story 111: per-role truly-idle wake — emit BEFORE the all-idle check,
        # since the two paths use different predicates. Both can fire same tick.
        now_ts = int(time.time())
        emit_per_role_wakes(project_root, live, now_ts)
    if live and check_predicate(project_root) == "idle":
        agents = gather_agent_summary(project_root, live)
        sys.stderr.write(f"[manager-monitor] all-idle detected, emitting event ({len(agents)} agents)\n")
        emit_idle_event(agents, project_root)


def main():
    if "--check-predicate" in sys.argv:
        project_root = find_project_root()
        print(check_predicate(project_root))
        return 0
    project_root = find_project_root()
    sys.stderr.write(f"[manager-monitor] starting, project_root={project_root}, interval={LOOP_INTERVAL}s\n")
    while True:
        try:
            # Two named concerns per tick. usage_concern runs OUTSIDE the
            # .nothing_to_do guard (the team can be declared-idle and still need
            # the 5h/7d usage signal); idle_concern carries the .nothing_to_do
            # guard + the per-role-wake / all-idle predicate internally.
            usage_concern(project_root)
            idle_concern(project_root)
        except Exception as e:
            sys.stderr.write(f"[manager-monitor] tick error: {e}\n")
        time.sleep(LOOP_INTERVAL)


if __name__ == "__main__":
    sys.exit(main() or 0)
