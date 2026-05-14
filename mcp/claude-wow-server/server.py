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
  - Prefer $CLAUDE_PROJECT_DIR (set by Claude Code at MCP-server spawn).
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

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "claude-wow"
SERVER_VERSION = "0.1.0"

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
    "learnings-updated",
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
])

# Story 069 amendment-3: bus_emit auto-injects a parallel
# read-token-discipline broadcast whenever called with one of these types.
# Mechanical at the MCP-call level — callers don't have to remember.
AUTO_INJECT_TRIGGERS = frozenset(["story-created", "sprint-kickoff"])
DOCTRINE_PATH = "commands/_token-discipline.md"

# Story 070: parallel mechanism for the retro doctrine. Disjoint trigger set
# from AUTO_INJECT_TRIGGERS, so the elif in handle_bus_emit is non-conflicting.
RETRO_AUTO_INJECT_TRIGGERS = frozenset(["review-closed", "retro-open"])
RETRO_DOCTRINE_PATH = "commands/_retro-doctrine.md"

# Agent-id pattern: <role>-<14digit-ts>-<6hex>
AGENT_ID_RE = re.compile(r"^[a-z-]+-[0-9]{8}T[0-9]{6}-[a-f0-9]{6}$")


def log(msg):
    sys.stderr.write(f"[claude-wow-mcp] {msg}\n")
    sys.stderr.flush()


def find_project_root():
    """Resolve consumer project root. Prefer $CLAUDE_PROJECT_DIR; else walk
    up from cwd to first ancestor with .claude-plugin/plugin.json or .git.
    Fail loud if neither found within 8 levels.
    """
    env_root = os.environ.get("CLAUDE_PROJECT_DIR")
    if env_root and os.path.isdir(env_root):
        return env_root
    log("WARN: CLAUDE_PROJECT_DIR unset, falling back to walk-up")
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
                    "bus event from the idle-monitor, AND only after independently "
                    "validating the team is truly done. When uncertain, message peers via "
                    "`bus_emit` before declaring idle. Writes a 'do not disturb' marker "
                    "that silences further idle-monitor nudges until `resume_work` is "
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
                    "re-enables idle-monitor nudges. Call on the user's explicit "
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
        with open(bus_path, "a") as f:
            f.write(serialized + inject_serialized)
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
        with open(bus_path, "a") as f:
            f.write(serialized + inject_serialized)
    else:
        with open(bus_path, "a") as f:
            f.write(serialized)

    return {"ok": True, "bus_path": bus_path}, None


def handle_declare_idle(args):
    import datetime
    reason = args.get("reason") if isinstance(args, dict) else None
    if reason is not None and not isinstance(reason, str):
        return None, {"code": -32602, "message": "reason must be string"}
    project_root = find_project_root()
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
    msg += " Idle-monitor nudges suppressed until resume_work is called."
    return {"content": [{"type": "text", "text": msg}]}, None


def handle_resume_work(args):
    project_root = find_project_root()
    marker_path = os.path.join(project_root, "implementations", ".nothing_to_do")
    existed = os.path.exists(marker_path)
    if existed:
        try:
            os.remove(marker_path)
        except OSError as e:
            return None, {"code": -32603, "message": f"failed to remove marker: {e}"}
    if existed:
        msg = "Work resumed. Idle-monitor nudges re-enabled."
    else:
        msg = "No marker present; resume_work was a no-op."
    return {"content": [{"type": "text", "text": msg}]}, None


def handle_tools_call(req_id, params):
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


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "bus_emit":
        cli_bus_emit(sys.argv[2:])
    main()
