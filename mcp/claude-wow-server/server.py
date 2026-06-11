#!/usr/bin/env python3
"""Claude-WOW plugin MCP server (Story 062).

Stdlib-only minimal JSON-RPC 2.0 stdio server. Currently exposes one tool:
  - bus_emit: append a structured JSONL line to the canonical project bus.

Protocol overview:
  - Read line-delimited JSON-RPC requests from stdin.
  - Write JSON-RPC responses to stdout (one JSON object per line).
  - Logs to stderr.
  - Long-lived: spawned by Claude Code at session start; loops until EOF.

Bus path resolution:
  - Prefer $WOW_ROOT (test-fixture / worktree override; aligns the CLI shim
    with the rest of the plugin's ${WOW_ROOT:-...} idiom), then
    $CLAUDE_PROJECT_DIR (set by Claude Code at MCP-server spawn).
  - Fallback: walk up from cwd to first ancestor containing
    .claude-plugin/plugin.json OR .git (8-level cap). Fail loud if neither
    found — silent miswrite to a wrong bus is the backlog 087 trap that
    this story fixes.
  - NEVER use `git rev-parse --show-toplevel` (worktree returns worktree path).
"""
import json
import os
import re
import sys
import time

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "claude-wow"
SERVER_VERSION = "0.1.0"

# Story 137 (backlog 157): MCP-server staleness self-detection. CC doesn't
# hot-reload MCP server source on disk-change — when a sprint merges a
# server.py change, the running process is stale until /reload-plugins.
# Story 103's sprint-mode code-review-suppression was inert across the entire
# 2026-05-18 sprint because the running server predated 103's merge. We
# capture our source mtime at startup; each tools/call compares it to the
# on-disk mtime; on drift, return a clear JSON-RPC error pointing the caller
# at /reload-plugins (JSON-RPC -32603 = Internal error — request is valid,
# server state is the problem).
_SERVER_SOURCE = os.path.abspath(__file__)
try:
    _SERVER_STARTUP_MTIME = os.path.getmtime(_SERVER_SOURCE)
except OSError:
    _SERVER_STARTUP_MTIME = None  # source not stat'able — staleness check disabled (fail-safe).


def _check_freshness():
    """Return None if fresh; an error message string if the source has been
    modified on disk since server startup."""
    if _SERVER_STARTUP_MTIME is None:
        return None
    try:
        current_mtime = os.path.getmtime(_SERVER_SOURCE)
    except OSError:
        return None  # source not readable — bail silently, no false-positive.
    if current_mtime <= _SERVER_STARTUP_MTIME:
        return None
    startup_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(_SERVER_STARTUP_MTIME))
    current_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(current_mtime))
    return (
        f"claude-wow MCP server source modified on disk after startup "
        f"(startup mtime: {startup_iso}, on-disk mtime: {current_iso}). "
        f"Run /reload-plugins in this Claude Code session to pick up the changes, then retry."
    )

# Allowed bus message types. Future stories that add new types must extend
# this enum. Two new types added by Story 062 itself:
# behavioral-change-flag / behavioral-change-cleared.
ALLOWED_TYPES = frozenset([
    # lifecycle
    "ping", "pong", "hello", "bye",
    # story / plan / pr lifecycle
    "story-created", "story-revised", "story-shipped",
    "story-shipped-correction", "story-closed", "story-parked",
    "story-verified",
    "plan-ready-for-review", "plan-reviewed", "plan-approved", "plan-done",
    "story-done",
    "bug-found", "bug-verified", "bug-triaged", "bug-fixing",
    "bug-fixed", "bug-closed",
    "pr-created", "pr-merged", "pr-nudge",
    # team coordination
    "nudge", "status", "question", "answer", "ack", "refused",
    "introspect", "introspection-done", "triage-done",
    "testability-concern",
    "worktree-released", "worktree-returned",
    "bus-wake-bug", "bus-restored",
    "skill-question", "skill-answer",
    "pp-checkpoint", "review-closed",
    "retro-open", "retro-input", "retro-learnings-window-open",
    "learnings-updated", "learnings-consolidated",
    "discovery-open", "discovery-input", "discovery-complete",
    "all-items-terminal", "human-afk", "human-back", "leader-decision",
    "version-coherence-repair", "backlog-suggest",
    "all-idle-nudge",
    # bridge events
    "bridge-status", "pr-state", "pr-comment", "pr-review",
    "pr-review-comment", "ci-check",
    # Story 062 additions: PP gate on _agent-protocol.md rewrite
    "behavioral-change-flag", "behavioral-change-cleared",
    # Story 069 amendment-3: sprint-kickoff (auto-inject trigger) +
    # read-token-discipline (auto-injected payload).
    "sprint-kickoff", "read-token-discipline",
    # Story 070: read-retro-doctrine (auto-injected payload on
    # review-closed / retro-open; both already in the enum above).
    "read-retro-doctrine",
    # Story 072: compaction-occurred (PostCompact hook → agent self).
    "compaction-occurred",
    # code-review-request: auto-injected to pair-programmer-* on every
    # pr-created bus_emit — triggers PP's automated code-review pass.
    "code-review-request",
    # Story 087: retro-flow / sprint types already used as doctrine by
    # manager.md (Step 2 sprint-ack) + _retro-doctrine.md (Step 1
    # retro-opening, Step 4 retro-close). Distinct from retro-open /
    # retro-input / retro-learnings-window-open / review-closed above.
    "sprint-ack", "retro-opening", "retro-close",
    # Story 101: read-skill — auto-injected role<->skill invocation reminder.
    "read-skill",
    # Story 124: read-learnings — auto-injected role-specific learnings refresh.
    "read-learnings",
    # Story 111: wake — manager-monitor's per-role truly-idle nudge.
    "wake",
    # Story 145: structured merge-authority grant convention. S relays a
    # human grant as a CANDIDATE (-grant); M echoes a structured (-ack) that
    # always requires explicit human confirm before authority goes active.
    "merge-authority-grant", "merge-authority-ack",
    # Story 172: opt-in usage auto-pause. The idle-limit-monitor daemon
    # bus-emits these carrying a bounded payload.directive ∈ {pause, resume,
    # escalate}. usage-limit-7d-escalate is addressed to: manager-* (M-private —
    # M acts on directive:escalate, peers ignore it; FINDING-47).
    "usage-limit-pause", "usage-limit-reset", "usage-limit-7d-escalate",
    # AHOD mode: kickoff / ack / stand-down + the auto-injected doctrine refresh.
    "ahod-kickoff", "ahod-ack", "ahod-stand-down", "read-ahod-doctrine",
])

# Story 069 amendment-3: bus_emit auto-injects a parallel
# read-token-discipline broadcast whenever called with one of these types.
# Mechanical at the MCP-call level — callers don't have to remember.
AUTO_INJECT_TRIGGERS = frozenset(["story-created", "sprint-kickoff", "ahod-kickoff"])
DOCTRINE_PATH = "commands/_token-discipline.md"

# Story 070: parallel mechanism for the retro doctrine. Disjoint trigger set
# from AUTO_INJECT_TRIGGERS, so the elif in handle_bus_emit is non-conflicting.
RETRO_AUTO_INJECT_TRIGGERS = frozenset(["review-closed", "retro-open"])
RETRO_DOCTRINE_PATH = "commands/_retro-doctrine.md"

# bus_emit auto-injects a code-review-request to pair-programmer-* whenever
# called with pr-created — PP then runs the code-review skill on the PR.
# Disjoint from the two trigger sets above (non-conflicting elif).
PR_CODE_REVIEW_TRIGGERS = frozenset(["pr-created"])


def _active_sprint_integration_branch(project_root):
    """integration_branch of THE active sprint manifest, or None (Story 103).

    $WOW_SPRINT_MANIFEST wins; else scan implementations/sprints/*/manifest.json,
    keyed on status == "active". Fail-safe: zero OR multiple active manifests =>
    None (multiple is a state bug; uncertainty => no suppression).
    """
    env = os.environ.get("WOW_SPRINT_MANIFEST")
    candidates = [env] if env else []
    if not candidates:
        sprints = os.path.join(project_root, "implementations", "sprints")
        if os.path.isdir(sprints):
            for d in sorted(os.listdir(sprints)):
                p = os.path.join(sprints, d, "manifest.json")
                if os.path.isfile(p):
                    candidates.append(p)
    active = []
    for p in candidates:
        try:
            with open(p) as f:
                m = json.load(f)
        except (OSError, json.JSONDecodeError, ValueError):
            continue
        if isinstance(m, dict) and m.get("status") == "active":
            active.append(m.get("integration_branch"))
    return active[0] if len(active) == 1 else None


# AHOD doctrine auto-inject. ahod-kickoff ALWAYS injects (the kickoff implies
# the mode); story-created / compaction-occurred inject only while
# implementations/config.json says mode == "ahod". Additive — fires alongside
# the doctrine / skill / learnings injects.
AHOD_DOCTRINE_PATH = "commands/_ahod-doctrine.md"
AHOD_MODE_DOCTRINE_TRIGGERS = frozenset(["story-created", "compaction-occurred"])


def _config_mode(project_root):
    """Project mode from implementations/config.json. Missing file, parse
    failure, or unexpected shape => "default" (AHOD behavior is strictly
    opt-in; uncertainty must not change default-mode behavior)."""
    path = os.path.join(project_root, "implementations", "config.json")
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError, ValueError):
        return "default"
    if isinstance(cfg, dict) and cfg.get("mode") == "ahod":
        return "ahod"
    return "default"

# Story 124: learnings auto-inject. Refresh role-specific learnings at three
# lifecycle moments — story-start (the dispatched role), sprint-kickoff (every
# role), and post-compaction (the affected agent). Disjoint from doctrine
# triggers; fires ADDITIVELY alongside whatever doctrine/skill inject is also
# firing. Recipient mirrors the original event's `to` field. The payload
# carries the `<role>` template path; each receiving role substitutes its own
# role name when reading.
LEARNINGS_AUTO_INJECT_TRIGGERS = frozenset(
    ["story-created", "sprint-kickoff", "compaction-occurred", "ahod-kickoff"]
)
LEARNINGS_PATH_TEMPLATE = "implementations/learnings/<role>.md"

# Story 101: role<->skill auto-inject. event-type -> (skill, recipient role-glob).
# Additive — fires ALONGSIDE any doctrine inject (e.g. story-created also triggers
# read-token-discipline). bus_emit injects a read-skill reminder so the recipient
# role invokes the named superpowers skill at this lifecycle point.
SKILL_INJECT_MAP = {
    "story-created": ("superpowers:writing-plans", "senior-developer-*"),
    "plan-approved": ("superpowers:executing-plans", "senior-developer-*"),
    "story-done": ("superpowers:verification-before-completion", "tester-*"),
}

# Agent-id pattern: <role>-<14digit-ts>-<6hex>
AGENT_ID_RE = re.compile(r"^[a-z-]+-[0-9]{8}T[0-9]{6}-[a-f0-9]{6}$")


def log(msg):
    sys.stderr.write(f"[claude-wow-mcp] {msg}\n")
    sys.stderr.flush()


def find_project_root():
    """Resolve consumer project root. Prefer $WOW_ROOT, then $CLAUDE_PROJECT_DIR;
    else walk up from cwd to first ancestor with .claude-plugin/plugin.json or .git.
    Fail loud if neither found within 8 levels.
    """
    wow_root = os.environ.get("WOW_ROOT")
    if wow_root and os.path.isdir(wow_root):
        return wow_root
    env_root = os.environ.get("CLAUDE_PROJECT_DIR")
    if env_root and os.path.isdir(env_root):
        return env_root
    log("WARN: WOW_ROOT/CLAUDE_PROJECT_DIR unset, falling back to walk-up")
    cur = os.getcwd()
    for _ in range(8):
        if os.path.isfile(os.path.join(cur, ".claude-plugin", "plugin.json")):
            return cur
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    raise RuntimeError(
        "Cannot resolve project root: $CLAUDE_PROJECT_DIR unset and no "
        ".claude-plugin/plugin.json or .git ancestor found within 8 levels"
    )


def jsonrpc_error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def jsonrpc_result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def handle_initialize(req_id, params):
    return jsonrpc_result(req_id, {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    })


def handle_tools_list(req_id, params):
    return jsonrpc_result(req_id, {
        "tools": [
            {
                "name": "bus_emit",
                "description": (
                    "Append a structured JSONL line to the project's "
                    "shared message bus at "
                    "${CLAUDE_PROJECT_DIR}/implementations/.message-bus.jsonl. "
                    "Replaces direct >> appends and the legacy "
                    "scripts/bus-emit.sh wrapper. Use for all inter-agent "
                    "communication."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "from": {
                            "type": "string",
                            "description": "Sender agent ID (<role>-<YYYYMMDDTHHmmss>-<6hex>)",
                        },
                        "type": {
                            "type": "string",
                            "description": "Message type (validated against allowed enum)",
                        },
                        "to": {
                            "type": "string",
                            "description": "Recipient: '*', '<role>-*', or exact agent ID",
                        },
                        "payload": {
                            "description": "Optional payload (any JSON value, passed through verbatim)",
                        },
                        "in_reply_to": {
                            "type": "string",
                            "description": "Optional ts of the message being replied to",
                        },
                    },
                    "required": ["from", "type", "to"],
                },
            },
            {
                "name": "declare_idle",
                "description": (
                    "M-only by convention. Call ONLY in response to an `all-idle-nudge` "
                    "bus event from the manager-monitor, AND only after independently "
                    "validating the team is truly done. When uncertain, message peers via "
                    "`bus_emit` before declaring idle. Writes a 'do not disturb' marker "
                    "that silences further manager-monitor nudges until `resume_work` is "
                    "called. Idempotent. Optional 'reason' field for audit trail. "
                    "Normaly this happens when a story/sprint is all done and "
                    "now the action is in human. Or, there is a hard blocker and work cannot proceed "
                    "thus all agents genuinely cannot proceed."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "reason": {
                            "type": "string",
                            "description": "Optional short rationale (e.g. 'backlog empty')."
                        }
                    },
                    "required": []
                }
            },
            {
                "name": "resume_work",
                "description": (
                    "M-only by convention. Clears the 'do not disturb' marker and "
                    "re-enables manager-monitor nudges. Call on the user's explicit "
                    "request (e.g. 'back to work') OR implicitly when the user "
                    "assigns new work, asks about progress, or otherwise signals "
                    "that the idle period has ended. Idempotent — safe to call "
                    "when no marker exists."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "monitor_event_read",
                "description": (
                    "Story 154 — load the full text of a Monitor event from a "
                    "monitor-pipe.sh-managed event file. CC's Monitor tool "
                    "truncates events at ~500 chars; the wrapper emits a short "
                    "pointer naming the event_file + 1-indexed line. Call this "
                    "tool with the pointer's values to fetch the raw line text. "
                    "Pure read; no side effects. Path-safe: rejects event_file "
                    "outside ${ROOT}/implementations/.monitor-events/."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "event_file": {
                            "type": "string",
                            "description": "Repo-relative path under implementations/.monitor-events/<purpose>/<task-id>.jsonl",
                        },
                        "line": {
                            "type": "integer",
                            "description": "1-indexed line number from the pointer",
                            "minimum": 1,
                        },
                    },
                    "required": ["event_file", "line"],
                },
            },
            {
                "name": "i_am_truly_idle",
                "description": "A peer (sd/pp/t) affirms it has genuinely nothing to do (no story/bug/review pending). Records the role's confirmed-idle bit in implementations/.truly-idle.json; declare_idle requires all of sd+pp+t confirmed + alive + quiet.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "role": {"type": "string", "description": "Caller role (senior-developer|pair-programmer|tester|manager|slacker)"},
                        "pid": {"type": "integer", "description": "Caller CC pid (optional; derived from .activity.jsonl / $CLAUDE_PID when omitted)"},
                    },
                    "required": ["role"],
                },
            }
        ]
    })


def validate_to(to):
    if to == "*":
        return True
    if to.endswith("-*"):
        return True
    if AGENT_ID_RE.match(to):
        return True
    return False


def now_iso():
    import datetime
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def handle_bus_emit(args):
    from_id = args.get("from")
    msg_type = args.get("type")
    to = args.get("to")
    payload = args.get("payload")
    in_reply_to = args.get("in_reply_to")

    if not from_id:
        return None, "missing required field: from"
    if not AGENT_ID_RE.match(from_id):
        return None, f"from '{from_id}' invalid; must match <role>-<YYYYMMDDTHHmmss>-<6hex>"
    if not msg_type:
        return None, "missing required field: type"
    if msg_type not in ALLOWED_TYPES:
        return None, f"type '{msg_type}' not in allowed enum"
    if not to:
        return None, "missing required field: to"
    if not validate_to(to):
        return None, f"to '{to}' invalid; must be '*', '<role>-*', or exact agent ID"

    project_root = find_project_root()
    mode = _config_mode(project_root)

    # Reject exact-ID sends to a non-live agent. A fabricated/dead exact ID
    # passes shape validation, gets written, and is then silently dropped by
    # every bus-tail filter (no live agent matches it). Require a tracker file.
    if to != "*" and not to.endswith("-*") and AGENT_ID_RE.match(to):
        tracker = os.path.join(project_root, "implementations", ".agents", to + ".json")
        if not os.path.exists(tracker):
            return None, (
                f"to '{to}' is not a live agent "
                f"(no implementations/.agents/{to}.json). "
                f"Use a role-glob '<role>-*' or a live agent ID."
            )

    bus_path = os.path.join(project_root, "implementations", ".message-bus.jsonl")
    os.makedirs(os.path.dirname(bus_path), exist_ok=True)

    line = {
        "ts": now_iso(),
        "from": from_id,
        "to": to,
        "type": msg_type,
    }
    if payload is not None:
        line["payload"] = payload
    if in_reply_to:
        line["in_reply_to"] = {"ts": in_reply_to}

    serialized = json.dumps(line, separators=(",", ":")) + "\n"

    # Doctrine auto-inject (Stories 069/070 + code-review-request) — at most one.
    # Story 101 hoisted the write out of the branches so the skill-inject below
    # can be ADDITIVE (a story-created emits read-token-discipline AND read-skill).
    inject_serialized = ""
    if msg_type in AUTO_INJECT_TRIGGERS:
        inject_line = {
            "ts": line["ts"],
            "from": from_id,
            "to": "*",
            "type": "read-token-discipline",
            "payload": {
                "path": DOCTRINE_PATH,
                "reason": f"auto-injected after {msg_type}",
            },
        }
        inject_serialized = json.dumps(inject_line, separators=(",", ":")) + "\n"
    elif msg_type in RETRO_AUTO_INJECT_TRIGGERS:
        inject_line = {
            "ts": line["ts"],
            "from": from_id,
            "to": "*",
            "type": "read-retro-doctrine",
            "payload": {
                "path": RETRO_DOCTRINE_PATH,
                "reason": f"auto-injected after {msg_type}",
            },
        }
        inject_serialized = json.dumps(inject_line, separators=(",", ":")) + "\n"
    elif msg_type in PR_CODE_REVIEW_TRIGGERS:
        # Story 103 / Decision B: suppress the per-item code-review auto-inject
        # for a per-item PR into an active sprint's integration branch. The
        # pr-created payload is a JSON string on the bus — parse it for the
        # `base` key (the PR's base branch; the canonical producer key — see
        # _agent-protocol.md). Any uncertainty (parse fail / non-dict / no
        # `base` / no single active manifest) falls through to the inject
        # (fail-safe — never silently drop). FINDING-36 (Story 137): this read
        # was `pr_base`, which no producer emits, so suppression was inert.
        integ = _active_sprint_integration_branch(project_root)
        pr_base = None
        pr_payload = payload
        if isinstance(pr_payload, str):
            try:
                pr_payload = json.loads(pr_payload)
            except (json.JSONDecodeError, ValueError):
                pr_payload = None
        if isinstance(pr_payload, dict):
            pr_base = pr_payload.get("base")
        if integ is not None and pr_base is not None and pr_base == integ:
            pass  # per-item PR into the active sprint integration branch — suppress
        else:
            inject_line = {
                "ts": line["ts"],
                "from": from_id,
                # AHOD: the relay is suspended — the PR author owns its own
                # review pass, so the cue routes back to the emitter.
                "to": from_id if mode == "ahod" else "pair-programmer-*",
                "type": "code-review-request",
                "payload": {
                    "reason": f"auto-injected after {msg_type}",
                    "pr_created_payload": payload,
                },
            }
            inject_serialized = json.dumps(inject_line, separators=(",", ":")) + "\n"

    # Story 101: additive role<->skill reminder — fires alongside any doctrine
    # inject above (e.g. story-created → read-token-discipline + read-skill).
    skill_inject_serialized = ""
    if msg_type in SKILL_INJECT_MAP:
        skill_name, role_glob = SKILL_INJECT_MAP[msg_type]
        if msg_type == "story-created" and mode == "ahod":
            # AHOD dispatch goes to the exact owner (any role) — the
            # writing-plans reminder follows the dispatch, not SD's glob.
            role_glob = to
        skill_line = {
            "ts": line["ts"],
            "from": from_id,
            "to": role_glob,
            "type": "read-skill",
            "payload": {
                "skill": skill_name,
                "event": msg_type,
                "reason": f"auto-injected after {msg_type}",
            },
        }
        skill_inject_serialized = json.dumps(skill_line, separators=(",", ":")) + "\n"

    # Story 124: additive read-learnings refresh — fires alongside any doctrine
    # or skill inject above (story-created → token-discipline + skill + learnings).
    # Recipient mirrors the original event's `to` so a sprint-kickoff broadcast
    # produces a learnings broadcast, story-created to senior-developer-* produces
    # a learnings to senior-developer-*, and compaction-occurred to <exact-id>
    # produces a learnings to that exact id.
    learnings_inject_serialized = ""
    if msg_type in LEARNINGS_AUTO_INJECT_TRIGGERS:
        learnings_line = {
            "ts": line["ts"],
            "from": from_id,
            "to": to,
            "type": "read-learnings",
            "payload": {
                "path": LEARNINGS_PATH_TEMPLATE,
                "reason": f"auto-injected after {msg_type}",
            },
        }
        learnings_inject_serialized = json.dumps(learnings_line, separators=(",", ":")) + "\n"

    # AHOD doctrine inject — ahod-kickoff always; story-created /
    # compaction-occurred only while mode == "ahod". Mirrors `to` on the
    # mode-gated triggers (learnings-inject precedent) so a reassignment or a
    # compaction mid-AHOD re-delivers the rulebook to exactly the owner.
    ahod_inject_serialized = ""
    if msg_type == "ahod-kickoff" or (
        msg_type in AHOD_MODE_DOCTRINE_TRIGGERS and mode == "ahod"
    ):
        ahod_line = {
            "ts": line["ts"],
            "from": from_id,
            "to": "*" if msg_type == "ahod-kickoff" else to,
            "type": "read-ahod-doctrine",
            "payload": {
                "path": AHOD_DOCTRINE_PATH,
                "reason": f"auto-injected after {msg_type}",
            },
        }
        ahod_inject_serialized = json.dumps(ahod_line, separators=(",", ":")) + "\n"

    # One write — original + doctrine inject + skill inject + learnings inject
    # + ahod inject — preserves the single-write atomicity guarantee (now up
    # to 5 contiguous lines).
    with open(bus_path, "a") as f:
        f.write(serialized + inject_serialized + skill_inject_serialized
                + learnings_inject_serialized + ahod_inject_serialized)

    return {"ok": True, "bus_path": bus_path}, None


def _pid_for_role_from_activity(project_root, role):
    """Story 181 — the role's most-recent claude_pid from .activity.jsonl (= the
    pid log-activity.sh records via $PPID, the CC session pid). Sourcing the
    truly-idle pid from here ties it to the gate's os.kill + activity-match by
    construction. Returns None if no row for the role."""
    act = os.path.join(project_root, "implementations", ".activity.jsonl")
    if not os.path.isfile(act):
        return None
    pid = None
    try:
        with open(act) as f:
            for line in f:
                try:
                    row = json.loads(line)
                except (ValueError, json.JSONDecodeError):
                    continue
                if isinstance(row, dict) and row.get("role") == role:
                    p = row.get("claude_pid")
                    if isinstance(p, int) and p > 0:
                        pid = p  # last match wins (most recent)
    except OSError:
        return None
    return pid


def handle_i_am_truly_idle(args):
    """Story 181 — a peer affirms it has genuinely nothing to do. Writes/updates
    implementations/.truly-idle.json[<role>] = {idle, ts, pid}. Idempotent per role."""
    import datetime
    if not isinstance(args, dict):
        return None, {"code": -32602, "message": "arguments must be object"}
    role = args.get("role")
    valid = {"manager", "senior-developer", "pair-programmer", "tester", "slacker"}
    if role not in valid:
        return None, {"code": -32602, "message": "role must be one of " + ", ".join(sorted(valid))}
    project_root = find_project_root()
    # PID identity: the stored pid MUST equal log-activity.sh's claude_pid (the
    # hook's $PPID = the CC session pid), else the gate's os.kill + activity-match
    # hit the wrong process. Source it from .activity.jsonl (the role's
    # most-recent claude_pid) -> identical by construction. os.getppid() is the
    # SERVER's parent, NOT the CC session. Explicit pid arg overrides (tests).
    pid = args.get("pid")
    if pid is None:
        pid = _pid_for_role_from_activity(project_root, role)
    if pid is None:
        env_pid = os.environ.get("CLAUDE_PID")
        if env_pid and env_pid.isdigit():
            pid = int(env_pid)
    if not isinstance(pid, int) or pid <= 0:
        return None, {"code": -32602, "message": f"cannot resolve pid for {role}: pass pid explicitly, or ensure .activity.jsonl has a row for the role"}
    path = os.path.join(project_root, "implementations", ".truly-idle.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f) or {}
        except (OSError, ValueError):
            data = {}
    if not isinstance(data, dict):
        data = {}
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    data[role] = {"idle": True, "ts": ts, "pid": pid}
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
        f.write("\n")
    os.replace(tmp, path)
    return {"content": [{"type": "text", "text": f"{role} marked truly-idle at {ts} (pid {pid})."}]}, None


def _truly_idle_offenders(project_root):
    """Story 181 — sd/pp/t must each be confirmed-idle + pid-alive + quiet (no
    WORK activity since their idle mark). Returns offender strings ([] = clear)."""
    required = ["senior-developer", "pair-programmer", "tester"]
    ti_path = os.path.join(project_root, "implementations", ".truly-idle.json")
    act_path = os.path.join(project_root, "implementations", ".activity.jsonl")
    data = {}
    if os.path.exists(ti_path):
        try:
            with open(ti_path) as f:
                data = json.load(f) or {}
        except (OSError, ValueError):
            data = {}
    if not isinstance(data, dict):
        data = {}

    # Only WORK-shaped rows count as "activity since idle". A trailing
    # stop/stop_failure/session_end is the END of a turn -- idle looks exactly
    # like that (it is what the manager-monitor's TERMINAL_TYPES keys on), NOT
    # resumed work; counting it would flag every genuinely-idle peer because the
    # stop always lands after the idle mark.
    _terminal = {"stop", "stop_failure", "session_end"}

    def latest_work_ts(pid):
        if not os.path.isfile(act_path):
            return None
        latest = None
        try:
            with open(act_path) as f:
                for line in f:
                    try:
                        row = json.loads(line)
                    except (ValueError, json.JSONDecodeError):
                        continue
                    if (isinstance(row, dict) and row.get("claude_pid") == pid
                            and row.get("type") not in _terminal):
                        t = row.get("ts")
                        if isinstance(t, str) and (latest is None or t > latest):
                            latest = t
        except OSError:
            return None
        return latest

    offenders = []
    for role in required:
        entry = data.get(role)
        if not isinstance(entry, dict) or not entry.get("idle"):
            offenders.append(f"{role} has not confirmed idle (no i_am_truly_idle)")
            continue
        pid, ts = entry.get("pid"), entry.get("ts")
        alive = False
        if isinstance(pid, int) and pid > 0:
            try:
                os.kill(pid, 0)
                alive = True
            except OSError:
                alive = False
        if not alive:
            offenders.append(f"{role} pid {pid} is dead (died after marking idle)")
            continue
        act_ts = latest_work_ts(pid)
        if act_ts is not None and isinstance(ts, str) and act_ts > ts:
            offenders.append(f"{role} has work activity since its idle mark ({act_ts} > {ts}) — it's working")
    return offenders


def handle_declare_idle(args):
    import datetime
    reason = args.get("reason") if isinstance(args, dict) else None
    if reason is not None and not isinstance(reason, str):
        return None, {"code": -32602, "message": "reason must be string"}
    project_root = find_project_root()
    offenders = _truly_idle_offenders(project_root)
    if offenders:
        return None, {"code": -32603, "message": "Refused — not declaring idle: " + "; ".join(offenders) + ". Nudge the offender(s) or wait."}
    marker_path = os.path.join(project_root, "implementations", ".nothing_to_do")
    os.makedirs(os.path.dirname(marker_path), exist_ok=True)
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    payload = {"ts": ts, "declared_by": "manager", "reason": reason}
    with open(marker_path, "w") as f:
        json.dump(payload, f)
        f.write("\n")
    msg = f"No-work mode declared at {ts}."
    if reason:
        msg += f" Reason: {reason}."
    msg += " manager-monitor nudges suppressed until resume_work is called."
    return {"content": [{"type": "text", "text": msg}]}, None


def handle_resume_work(args):
    project_root = find_project_root()
    marker_path = os.path.join(project_root, "implementations", ".nothing_to_do")
    ti_path = os.path.join(project_root, "implementations", ".truly-idle.json")
    existed = os.path.exists(marker_path)
    if existed:
        try:
            os.remove(marker_path)
        except OSError as e:
            return None, {"code": -32603, "message": f"failed to remove marker: {e}"}
    # Story 181 — also reset all per-role truly-idle bits: a resumed team
    # re-affirms idle from scratch (no stale confirmation gates the next declare).
    ti_reset = False
    if os.path.exists(ti_path):
        try:
            os.remove(ti_path)
            ti_reset = True
        except OSError as e:
            return None, {"code": -32603, "message": f"failed to reset truly-idle: {e}"}
    if existed or ti_reset:
        msg = "Work resumed. manager-monitor nudges re-enabled; truly-idle confirmations reset (team re-affirms idle from scratch)."
    else:
        msg = "No marker present; resume_work was a no-op."
    return {"content": [{"type": "text", "text": msg}]}, None


def handle_monitor_event_read(args):
    if not isinstance(args, dict):
        return None, {"code": -32602, "message": "arguments must be object"}
    event_file = args.get("event_file")
    line_no = args.get("line")
    if not isinstance(event_file, str) or not event_file:
        return None, {"code": -32602, "message": "event_file must be non-empty string"}
    if not isinstance(line_no, int) or line_no < 1:
        return None, {"code": -32602, "message": "line must be positive integer"}

    project_root = find_project_root()
    monitor_events_root = os.path.realpath(
        os.path.join(project_root, "implementations", ".monitor-events")
    )
    requested_abs = os.path.realpath(os.path.join(project_root, event_file))

    if not (requested_abs == monitor_events_root or
            requested_abs.startswith(monitor_events_root + os.sep)):
        err_text = json.dumps({
            "error": "event_file is outside implementations/.monitor-events/",
            "event_file": event_file,
            "line": line_no,
        })
        return {"content": [{"type": "text", "text": err_text}]}, None

    if not os.path.isfile(requested_abs):
        err_text = json.dumps({
            "error": "event_file does not exist (purpose not armed, or trimmed)",
            "event_file": event_file,
            "line": line_no,
        })
        return {"content": [{"type": "text", "text": err_text}]}, None

    try:
        with open(requested_abs, "r", encoding="utf-8", errors="replace") as f:
            for idx, raw in enumerate(f, start=1):
                if idx == line_no:
                    event_text = raw.rstrip("\n")
                    payload = json.dumps({"event": event_text})
                    return {"content": [{"type": "text", "text": payload}]}, None
    except OSError as e:
        return None, {"code": -32603, "message": f"failed to read event_file: {e}"}

    err_text = json.dumps({
        "error": "line out of range (file may have been trimmed; pointer stale)",
        "event_file": event_file,
        "line": line_no,
    })
    return {"content": [{"type": "text", "text": err_text}]}, None


def handle_tools_call(req_id, params):
    # Story 137 (backlog 157): refuse every tools/call when the server source
    # has been modified on disk since startup — caller's response is to run
    # /reload-plugins (the error message says so explicitly). Single check
    # point covers all three current tools (bus_emit, declare_idle,
    # resume_work) and any future ones automatically.
    stale_err = _check_freshness()
    if stale_err is not None:
        return jsonrpc_error(req_id, -32603, stale_err)
    name = params.get("name")
    args = params.get("arguments", {})
    if name == "bus_emit":
        result, err = handle_bus_emit(args)
        if err:
            return jsonrpc_error(req_id, -32602, err)
        return jsonrpc_result(req_id, {"content": [{"type": "text", "text": json.dumps(result)}]})
    elif name == "declare_idle":
        result, err = handle_declare_idle(args)
        if err:
            return jsonrpc_error(req_id, err["code"], err["message"])
        return jsonrpc_result(req_id, result)
    elif name == "resume_work":
        result, err = handle_resume_work(args)
        if err:
            return jsonrpc_error(req_id, err["code"], err["message"])
        return jsonrpc_result(req_id, result)
    elif name == "monitor_event_read":
        result, err = handle_monitor_event_read(args)
        if err:
            return jsonrpc_error(req_id, err["code"], err["message"])
        return jsonrpc_result(req_id, result)
    elif name == "i_am_truly_idle":
        result, err = handle_i_am_truly_idle(args)
        if err:
            return jsonrpc_error(req_id, err["code"], err["message"])
        return jsonrpc_result(req_id, result)
    return jsonrpc_error(req_id, -32601, f"Tool not found: {name}")


def main():
    log(f"server starting (PROTOCOL_VERSION={PROTOCOL_VERSION}, SERVER_VERSION={SERVER_VERSION})")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            log(f"JSON parse error: {e}")
            sys.stdout.write(json.dumps(jsonrpc_error(None, -32700, f"Parse error: {e}")) + "\n")
            sys.stdout.flush()
            continue
        method = req.get("method")
        req_id = req.get("id")
        params = req.get("params") or {}
        if method == "initialize":
            resp = handle_initialize(req_id, params)
        elif method == "notifications/initialized":
            continue  # notification — no response expected
        elif method == "tools/list":
            resp = handle_tools_list(req_id, params)
        elif method == "tools/call":
            resp = handle_tools_call(req_id, params)
        else:
            resp = jsonrpc_error(req_id, -32601, f"Method not found: {method}")
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
    log("server exiting (EOF)")


def cli_bus_emit(argv):
    """Story 072 CLI shim — invoked when hooks run as shell subprocesses.

    Usage: server.py bus_emit --from <id> --to <id> --type <type> [--payload-json <json>] [--in-reply-to <ts>]

    Reuses handle_bus_emit for validation + atomic append. Exits 0 success,
    2 validation error, 3 IO error.
    """
    import argparse
    p = argparse.ArgumentParser(prog="server.py bus_emit")
    p.add_argument("--from", dest="from_id", required=True)
    p.add_argument("--to", required=True)
    p.add_argument("--type", required=True)
    p.add_argument("--payload-json", dest="payload_json", default=None)
    p.add_argument("--in-reply-to", dest="in_reply_to", default=None)
    args = p.parse_args(argv)
    emit_args = {"from": args.from_id, "to": args.to, "type": args.type}
    if args.payload_json is not None:
        try:
            emit_args["payload"] = json.loads(args.payload_json)
        except json.JSONDecodeError as e:
            sys.stderr.write(f"--payload-json parse error: {e}\n")
            sys.exit(2)
    if args.in_reply_to:
        emit_args["in_reply_to"] = args.in_reply_to
    try:
        result, err = handle_bus_emit(emit_args)
    except OSError as e:
        sys.stderr.write(f"bus_emit IO error: {e}\n")
        sys.exit(3)
    if err:
        sys.stderr.write(f"bus_emit validation error: {err}\n")
        sys.exit(2)
    sys.stdout.write(json.dumps(result) + "\n")
    sys.exit(0)


def _cli_idle_tool(tool, handler, argv):
    """Story 181 CLI shim for the idle tools (tests/hooks drive them as subprocesses).
    Usage: server.py <i_am_truly_idle|declare_idle|resume_work> [--role R] [--pid N] [--reason T]
    Exits 0 success, 2 validation error, 3 IO error."""
    import argparse
    p = argparse.ArgumentParser(prog=f"server.py {tool}")
    p.add_argument("--role", default=None)
    p.add_argument("--pid", type=int, default=None)
    p.add_argument("--reason", default=None)
    a = p.parse_args(argv)
    call = {}
    if a.role is not None:
        call["role"] = a.role
    if a.pid is not None:
        call["pid"] = a.pid
    if a.reason is not None:
        call["reason"] = a.reason
    try:
        result, err = handler(call)
    except OSError as e:
        sys.stderr.write(f"{tool} IO error: {e}\n")
        sys.exit(3)
    if err:
        sys.stderr.write(f"{tool} error: {err.get('message', err)}\n")
        sys.exit(2)
    sys.stdout.write(json.dumps(result) + "\n")
    sys.exit(0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "bus_emit":
        cli_bus_emit(sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "i_am_truly_idle":
        _cli_idle_tool("i_am_truly_idle", handle_i_am_truly_idle, sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "declare_idle":
        _cli_idle_tool("declare_idle", handle_declare_idle, sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "resume_work":
        _cli_idle_tool("resume_work", handle_resume_work, sys.argv[2:])
    main()
