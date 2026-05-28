#!/usr/bin/env python3
"""bridge/github/run.py — GitHub PR bridge for WOW.

Polls watched repos via `gh api`, emits JSONL events to stdout on PR
state transitions (`pr-state`), reviews (`pr-review`), comments
(`pr-comment`), CI checks (`ci-check`), and own lifecycle changes
(`bridge-status`). Optional webhook mode via the `cli/gh-webhook`
extension delivers events in real time; polling stays armed at a slower
cadence as a safety net. Python stdlib only.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_POLLING_INTERVAL_SEC = 30
DEFAULT_WEBHOOK_SAFETY_NET_INTERVAL_SEC = 300
GH_TIMEOUT_SEC = 20
DEGRADATION_THRESHOLD = 3
WEBHOOK_FORWARD_RESTART_MAX = 3
WEBHOOK_FORWARD_RESTART_BACKOFF_SEC = 30
WEBHOOK_EVENTS = (
    "pull_request,pull_request_review,pull_request_review_comment,"
    "issue_comment,check_suite"
)

# Re-arm subsystem. When a forwarder exhausts the
# initial 3-retry budget, the supervisor transitions to a re-arm phase
# that probes network and re-spawns on a backoff cadence. Cadence and
# recovery threshold are env-overridable for test-time compression.
REARM_CADENCE_SEC = [30, 60, 120, 300, 900, 1800]  # last value plateaus
REARM_RECOVERY_THRESHOLD_SEC = int(
    os.environ.get("BRIDGE_REARM_RECOVERY_THRESHOLD_SEC", "300")
)
REARM_INITIAL_INTERVAL_SEC_OVERRIDE = os.environ.get(
    "BRIDGE_REARM_INITIAL_INTERVAL_SEC"
)
REARM_PROBE_TIMEOUT_SEC = 5
BRIDGE_PID_FILENAME = ".bridge-pid"
FORWARDER_LOG_MAX_BYTES = 1_000_000  # 1 MB rotate-truncate
FORWARDER_STDERR_DEQUE_MAXLEN = 200
LAST_STDERR_LINES_IN_PAYLOAD = 3
LAST_STDERR_LINE_TRUNCATE = 200

_running = True

# Per-repo SIGUSR1 fast-path events (set by signal handler, awaited by
# the re-arm loop's timed wait). Story 011 / Section C.
_rearm_fire_now: dict[str, threading.Event] = {}
_rearm_fire_now_lock = threading.Lock()

# Per-repo rolling stderr deques + their lock (read by emit-time
# _last_stderr_payload). Story 011 / Section D.
_forwarder_stderr: dict[str, "collections.deque[str]"] = {}
_forwarder_stderr_lock = threading.Lock()

# Per-PR lock registry for cursor-write safety when polling and webhook
# threads can both touch the same cursor file. Coarser than per-cursor-
# write because we want the read+process+write to be one critical
# section per (repo, pr_num).
_pr_locks: dict[tuple[str, int], threading.Lock] = {}
_pr_locks_master = threading.Lock()


def _get_pr_lock(repo: str, pr_num: int) -> threading.Lock:
    with _pr_locks_master:
        key = (repo, pr_num)
        lock = _pr_locks.get(key)
        if lock is None:
            lock = threading.Lock()
            _pr_locks[key] = lock
        return lock


# Set of repos forced to polling-only mode at startup or after a webhook
# forwarder exhausts its restart budget. Mutated by main + supervisor
# threads under _polling_only_lock.
_polling_only: set[str] = set()
_polling_only_lock = threading.Lock()
# Live forwarder children (subprocess.Popen) to terminate on shutdown.
_forwarder_children: list[subprocess.Popen] = []
_forwarder_children_lock = threading.Lock()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _emit(bridge_id: str, ev_type: str, payload: dict) -> None:
    line = json.dumps(
        {
            "ts": _now_iso(),
            "from": bridge_id,
            "to": "manager-*",
            "type": ev_type,
            "payload": json.dumps(payload, separators=(",", ":")),
        },
        separators=(",", ":"),
    )
    print(line, flush=True)


def _state_from_pr(pr: dict) -> str:
    state = pr.get("state")
    merged_at = pr.get("merged_at")
    draft = bool(pr.get("draft", False))
    if state == "closed":
        return "merged" if merged_at else "closed"
    if draft:
        return "draft"
    return "ready_for_review"


def _read_cursor(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if (
        isinstance(data, dict)
        and "last_comment_id" in data
        and "last_issue_comment_id" not in data
        and "last_review_comment_id" not in data
    ):
        data["last_issue_comment_id"] = data["last_comment_id"]
        data["last_review_comment_id"] = data["last_comment_id"]
        del data["last_comment_id"]
    return data


def _write_cursor(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, separators=(",", ":")))
    os.replace(str(tmp), str(path))


def _gh_api(api_path: str) -> list | dict:
    """Run `gh api <path>` and return the parsed JSON. Most endpoints
    return a list (collections); some return a dict (e.g. check-suites
    wraps `{check_suites: [...]}`, repo metadata returns object).
    """
    proc = subprocess.run(
        ["gh", "api", api_path],
        capture_output=True,
        text=True,
        timeout=GH_TIMEOUT_SEC,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"gh api {api_path} failed (rc={proc.returncode}): {proc.stderr.strip()[:200]}"
        )
    return json.loads(proc.stdout)


_REVIEW_STATE_MAP = {
    "APPROVED": "approved",
    "CHANGES_REQUESTED": "changes_requested",
    "COMMENTED": "commented",
    "DISMISSED": "commented",
}


def _process_pr_state(
    bridge_id: str,
    repo: str,
    pr_num: int,
    current_state: str,
    cursor: dict,
    pr_url: str,
    actor: str | None,
) -> None:
    """Compare current PR state to cursor and emit pr-state on transition.

    First observation per PR (no prior "state" in cursor) populates without
    emit — same no-replay semantics shared by all per-PR cursor fields.
    Mutates cursor in place.
    """
    if "state" not in cursor:
        cursor["state"] = current_state
        return
    if cursor["state"] == current_state:
        return
    _emit(
        bridge_id,
        "pr-state",
        {
            "repo": repo,
            "pr": pr_num,
            "from_state": cursor.get("state"),
            "to_state": current_state,
            "actor": actor,
            "url": pr_url or None,
        },
    )
    cursor["state"] = current_state


def _process_review(
    bridge_id: str,
    repo: str,
    pr_num: int,
    review: dict,
    cursor: dict,
    pr_url: str,
    *,
    populating: bool,
) -> None:
    """Emit pr-review for one review row if its id is newer than the
    cursor's last_review_id; otherwise no-op. Always advances
    cursor["last_review_id"] to the max seen.
    """
    rid = review.get("id")
    if not isinstance(rid, int):
        return
    prior_max = int(cursor.get("last_review_id", 0))
    new_max = max(prior_max, rid)
    cursor["last_review_id"] = new_max
    if populating or rid <= prior_max:
        return
    gh_state = (review.get("state") or "").upper()
    state = _REVIEW_STATE_MAP.get(gh_state, "commented")
    reviewer = ((review.get("user") or {}).get("login")) or None
    _emit(
        bridge_id,
        "pr-review",
        {
            "repo": repo,
            "pr": pr_num,
            "reviewer": reviewer,
            "state": state,
            "body": review.get("body") or "",
            "url": review.get("html_url") or pr_url,
        },
    )


def _process_comment(
    bridge_id: str,
    repo: str,
    pr_num: int,
    comment: dict,
    kind: str,
    cursor: dict,
    pr_url: str,
    *,
    populating: bool,
) -> None:
    """Emit pr-comment for one comment row if its id is newer than the
    cursor's per-kind max-seen field; otherwise no-op. Always advances
    that field to the max seen.

    /issues/<N>/comments and /pulls/<N>/comments use different ID-space
    generators, so the cursor tracks each kind in its own field
    (`last_issue_comment_id` / `last_review_comment_id`); using a single
    shared field allows higher IDs from one kind to silently shadow
    lower IDs from the other (PR #7's silent-drop bug).
    """
    cid = comment.get("id")
    if not isinstance(cid, int):
        return
    field = (
        "last_issue_comment_id"
        if kind == "issue_comment"
        else "last_review_comment_id"
    )
    prior_max = int(cursor.get(field, 0))
    new_max = max(prior_max, cid)
    cursor[field] = new_max
    if populating or cid <= prior_max:
        return
    author = ((comment.get("user") or {}).get("login")) or None
    _emit(
        bridge_id,
        "pr-comment",
        {
            "repo": repo,
            "pr": pr_num,
            "author": author,
            "body": comment.get("body") or "",
            "url": comment.get("html_url") or pr_url,
            "kind": kind,
        },
    )


def _emit_review_events(
    bridge_id: str,
    repo: str,
    pr_num: int,
    cursor: dict,
    pr_url: str,
    *,
    populating: bool,
) -> None:
    """Polling-side wrapper: fetch /pulls/<N>/reviews and route each row
    through _process_review.

    `populating` is a snapshot taken at the call site BEFORE
    `_process_pr_state` runs, so it reflects "is this the first poll for
    this PR" (i.e. did the cursor have `state` set already). On first
    poll, suppress all review emits — the goal is to populate cursor
    fields without flooding M with the deluge of historical reviews.
    """
    reviews = _gh_api(f"/repos/{repo}/pulls/{pr_num}/reviews")
    if not isinstance(reviews, list):
        return
    sorted_reviews = sorted(
        (r for r in reviews if isinstance(r.get("id"), int)),
        key=lambda r: r["id"],
    )
    for review in sorted_reviews:
        _process_review(
            bridge_id, repo, pr_num, review, cursor, pr_url,
            populating=populating,
        )


def _emit_comment_events(
    bridge_id: str,
    repo: str,
    pr_num: int,
    cursor: dict,
    pr_url: str,
    *,
    populating: bool,
) -> None:
    """Polling-side wrapper: fetch BOTH /issues/<N>/comments and
    /pulls/<N>/comments, tag each by kind, route through _process_comment.

    `populating` is the same snapshot used for `_emit_review_events` —
    taken at the call site before `_process_pr_state` mutates cursor.
    Single per-pass populating value applies to both kinds; first poll
    suppresses all historical comments regardless of issue-vs-review
    origin.
    """
    issue_comments = _gh_api(f"/repos/{repo}/issues/{pr_num}/comments")
    if not isinstance(issue_comments, list):
        issue_comments = []
    review_comments = _gh_api(f"/repos/{repo}/pulls/{pr_num}/comments")
    if not isinstance(review_comments, list):
        review_comments = []

    tagged: list[tuple[int, dict, str]] = []
    for c in issue_comments:
        cid = c.get("id")
        if isinstance(cid, int):
            tagged.append((cid, c, "issue_comment"))
    for c in review_comments:
        cid = c.get("id")
        if isinstance(cid, int):
            tagged.append((cid, c, "review_thread"))

    tagged.sort(key=lambda x: x[0])
    for _, c, kind in tagged:
        _process_comment(
            bridge_id, repo, pr_num, c, kind, cursor, pr_url,
            populating=populating,
        )


def _process_ci_check(
    bridge_id: str,
    repo: str,
    pr_num: int,
    sha: str,
    suite: dict,
    cursor: dict,
) -> None:
    """Compare a check-suite's current {status, conclusion} to the cursor's
    last-seen state for the same suite id and emit ci-check on transition.

    Cursor field: cursor["last_seen_check_states"] is a dict mapping
    str(suite_id) -> {"status": ..., "conclusion": ...}. First observation
    of a suite id populates without emit; subsequent ticks emit one
    ci-check per actual {status, conclusion} change. A max-id cursor would
    silently drop second/third transitions on the same suite — see story
    AC for the rationale.
    """
    suite_id = suite.get("id")
    if not isinstance(suite_id, int):
        return
    current = {
        "status": suite.get("status"),
        "conclusion": suite.get("conclusion"),
    }
    states = cursor.setdefault("last_seen_check_states", {})
    key = str(suite_id)
    prior = states.get(key)
    if prior is None:
        states[key] = current
        return
    if prior == current:
        return
    states[key] = current
    suite_name = ((suite.get("app") or {}).get("slug")) or str(suite_id)
    _emit(
        bridge_id,
        "ci-check",
        {
            "repo": repo,
            "pr": pr_num,
            "sha": sha,
            "suite": suite_name,
            "status": current["status"],
            "conclusion": current["conclusion"],
        },
    )


def _emit_ci_events(
    bridge_id: str,
    repo: str,
    pr_num: int,
    sha: str,
    cursor: dict,
) -> None:
    """Polling-side wrapper: fetch /commits/<sha>/check-suites and route
    each suite through _process_ci_check.
    """
    if not sha:
        return
    body = _gh_api(f"/repos/{repo}/commits/{sha}/check-suites")
    if isinstance(body, dict):
        suites = body.get("check_suites", [])
    elif isinstance(body, list):
        suites = body
    else:
        suites = []
    sorted_suites = sorted(
        (s for s in suites if isinstance(s.get("id"), int)),
        key=lambda s: s["id"],
    )
    for suite in sorted_suites:
        _process_ci_check(bridge_id, repo, pr_num, sha, suite, cursor)


def _slug(repo: str) -> str:
    return repo.replace("/", "-")


def _check_webhook_extension() -> bool:
    """Return True if the `cli/gh-webhook` extension (or a fork carrying
    `gh-webhook` in its name) is installed. False on any subprocess error
    — caller treats False as "fall back to polling-only".
    """
    try:
        proc = subprocess.run(
            ["gh", "extension", "list"],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT_SEC,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        return False
    if proc.returncode != 0:
        return False
    return "gh-webhook" in proc.stdout


def _check_admin(repo: str) -> bool:
    """Probe `gh api /repos/<repo>` and return whether the auth'd user has
    admin permissions on the repo. False on any error.
    """
    try:
        body = _gh_api(f"/repos/{repo}")
    except Exception:
        return False
    if not isinstance(body, dict):
        return False
    perms = body.get("permissions") or {}
    return bool(perms.get("admin"))


def _process_webhook_event(
    bridge_id: str,
    event_type: str,
    payload: dict,
    cursor_root: Path,
) -> None:
    """Webhook ingress: extract per-PR fields, lock the PR's cursor, route
    the row through the same _process_* helper as polling, write the
    cursor.

    On any extraction error or unhandled event type, return silently.
    """
    repo_obj = payload.get("repository") or {}
    repo = repo_obj.get("full_name")
    if not repo:
        return

    pr_num: int | None = None
    pr_url: str = ""

    if event_type == "pull_request":
        pr = payload.get("pull_request") or {}
        pr_num = pr.get("number")
        pr_url = pr.get("html_url") or ""
    elif event_type == "pull_request_review":
        pr = payload.get("pull_request") or {}
        pr_num = pr.get("number")
        pr_url = pr.get("html_url") or ""
    elif event_type == "pull_request_review_comment":
        pr = payload.get("pull_request") or {}
        pr_num = pr.get("number")
        pr_url = pr.get("html_url") or ""
    elif event_type == "issue_comment":
        issue = payload.get("issue") or {}
        if not issue.get("pull_request"):
            return  # plain issue, not a PR comment
        pr_num = issue.get("number")
        pr_url = issue.get("html_url") or ""
    elif event_type == "check_suite":
        suite = payload.get("check_suite") or {}
        prs = suite.get("pull_requests") or []
        if not prs:
            return
        # check_suite can fan out to multiple PRs (cross-branch / fork);
        # emit per associated PR using the same suite payload.
        for pr in prs:
            pn = pr.get("number")
            if not isinstance(pn, int):
                continue
            _route_check_suite(bridge_id, repo, pn, suite, cursor_root)
        return
    else:
        return

    if not isinstance(pr_num, int):
        return

    lock = _get_pr_lock(repo, pr_num)
    with lock:
        cursor_path = cursor_root / _slug(repo) / f"pr-{pr_num}.cursor"
        prior = _read_cursor(cursor_path)
        cursor: dict = dict(prior) if prior is not None else {}

        if event_type == "pull_request":
            pr_dict = payload.get("pull_request") or {}
            current_state = _state_from_pr(pr_dict)
            actor = ((payload.get("sender") or {}).get("login")) or None
            _process_pr_state(
                bridge_id, repo, pr_num, current_state, cursor, pr_url, actor,
            )
        elif event_type == "pull_request_review":
            review = payload.get("review") or {}
            _process_review(
                bridge_id, repo, pr_num, review, cursor, pr_url,
                populating=False,
            )
        elif event_type == "pull_request_review_comment":
            comment = payload.get("comment") or {}
            _process_comment(
                bridge_id, repo, pr_num, comment, "review_thread",
                cursor, pr_url, populating=False,
            )
        elif event_type == "issue_comment":
            comment = payload.get("comment") or {}
            _process_comment(
                bridge_id, repo, pr_num, comment, "issue_comment",
                cursor, pr_url, populating=False,
            )

        cursor["last_seen_ts"] = _now_iso()
        _write_cursor(cursor_path, cursor)


def _route_check_suite(
    bridge_id: str,
    repo: str,
    pr_num: int,
    suite: dict,
    cursor_root: Path,
) -> None:
    """Helper for webhook check_suite events — locks the PR cursor,
    invokes _process_ci_check, writes the cursor.
    """
    lock = _get_pr_lock(repo, pr_num)
    with lock:
        cursor_path = cursor_root / _slug(repo) / f"pr-{pr_num}.cursor"
        prior = _read_cursor(cursor_path)
        cursor: dict = dict(prior) if prior is not None else {}
        sha = suite.get("head_sha") or ""
        _process_ci_check(bridge_id, repo, pr_num, sha, suite, cursor)
        cursor["last_seen_ts"] = _now_iso()
        _write_cursor(cursor_path, cursor)


class _WebhookHandler(BaseHTTPRequestHandler):
    """Receives POSTs from `gh webhook forward`. The handler extracts the
    GitHub event type from the X-GitHub-Event header, parses the body as
    JSON, and routes through _process_webhook_event.
    """

    # Filled in by the bridge before serve_forever() is called.
    bridge_id: str = ""
    cursor_root: Path = Path(".")

    def log_message(self, format, *args):  # noqa: A003 — silence access log
        return

    def do_POST(self):  # noqa: N802 — http.server convention
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
            body_bytes = self.rfile.read(length) if length > 0 else b""
            event = self.headers.get("X-GitHub-Event") or ""
            payload = json.loads(body_bytes.decode("utf-8") or "{}")
        except (ValueError, OSError):
            self.send_response(400)
            self.end_headers()
            return
        try:
            _process_webhook_event(
                self.bridge_id, event, payload, self.cursor_root,
            )
        except Exception as exc:
            sys.stderr.write(f"[webhook] error processing {event}: {exc}\n")
        self.send_response(204)
        self.end_headers()


class _BridgeWebhookServer(ThreadingHTTPServer):
    # SO_REUSEADDR — allows binding a port that's just been released by
    # the test's ephemeral-port allocator. Without this the bridge fails
    # to bind a port still in TIME_WAIT.
    allow_reuse_address = True


def _start_webhook_listener(
    bridge_id: str, port: int, cursor_root: Path,
) -> ThreadingHTTPServer:
    _WebhookHandler.bridge_id = bridge_id
    _WebhookHandler.cursor_root = cursor_root
    server = _BridgeWebhookServer(("127.0.0.1", port), _WebhookHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# --- Story 011 helpers (Sections B, C, D, A) -------------------------------

def _drain_forwarder_stderr(
    repo: str, child: subprocess.Popen, log_path: Path,
) -> None:
    """Daemon thread reads forwarder child's stderr line-by-line; appends
    to a per-repo deque AND to a per-repo log file (truncate-rotate at
    1 MB). Story 011 / Section D.
    """
    if child.stderr is None:
        return
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    while True:
        try:
            raw = child.stderr.readline()
        except (OSError, ValueError):
            return
        if not raw:
            return
        try:
            line = raw.decode("utf-8", errors="replace").rstrip("\n").rstrip("\r")
        except Exception:
            line = ""
        if not line:
            continue
        with _forwarder_stderr_lock:
            dq = _forwarder_stderr.setdefault(
                repo, collections.deque(maxlen=FORWARDER_STDERR_DEQUE_MAXLEN)
            )
            dq.append(line)
        try:
            try:
                size = os.path.getsize(log_path)
            except OSError:
                size = 0
            if size > FORWARDER_LOG_MAX_BYTES:
                # Truncate then re-seed from the deque snapshot.
                with _forwarder_stderr_lock:
                    snapshot = list(_forwarder_stderr.get(repo, []))
                with open(log_path, "w") as fh:
                    for ln in snapshot:
                        fh.write(ln + "\n")
            else:
                with open(log_path, "a") as fh:
                    fh.write(line + "\n")
        except OSError:
            pass


def _last_stderr_payload(repo: str) -> dict | None:
    """Snapshot the last N stderr lines for a repo, truncated and joined,
    returned as a dict ready to merge into a bridge-status payload. None
    if the deque is empty.
    """
    with _forwarder_stderr_lock:
        dq = _forwarder_stderr.get(repo)
        if not dq:
            return None
        snapshot = list(dq)
    tail = snapshot[-LAST_STDERR_LINES_IN_PAYLOAD:]
    truncated = [s[:LAST_STDERR_LINE_TRUNCATE] for s in tail]
    return {"last_stderr": " | ".join(truncated)}


def _emit_with_stderr(
    bridge_id: str, repo: str, state: str, reason: str,
) -> None:
    """Wrapper around _emit for bridge-status events that should carry
    last_stderr if available. Story 011 / Section D.
    """
    payload: dict = {"state": state, "reason": reason}
    extra = _last_stderr_payload(repo)
    if extra:
        payload.update(extra)
    _emit(bridge_id, "bridge-status", payload)


def _probe_network(bridge_id: str, repo: str) -> bool:
    """Run `gh api rate_limit` with a 5s timeout. Returns True on success;
    on failure emits bridge-status: degraded with the reason and returns
    False. The rate_limit endpoint doesn't count against itself.
    Story 011 / Section B.
    """
    try:
        proc = subprocess.run(
            ["gh", "api", "rate_limit"],
            capture_output=True,
            timeout=REARM_PROBE_TIMEOUT_SEC,
        )
    except subprocess.TimeoutExpired:
        _emit_with_stderr(
            bridge_id, repo, "degraded",
            f"probe-failed for {repo}: gh api rate_limit timed out after "
            f"{REARM_PROBE_TIMEOUT_SEC}s",
        )
        return False
    except (subprocess.SubprocessError, FileNotFoundError) as exc:
        _emit_with_stderr(
            bridge_id, repo, "degraded",
            f"probe-failed for {repo}: {str(exc)[:200]}",
        )
        return False
    if proc.returncode != 0:
        tail = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
        _emit_with_stderr(
            bridge_id, repo, "degraded",
            f"probe-failed for {repo}: gh api rate_limit failed "
            f"(rc={proc.returncode}): {tail[:200]}",
        )
        return False
    return True


def _on_user_presence(_signum, _frame):
    """SIGUSR1 — fire all per-repo re-arm timers immediately.
    Signal-async-safe: only acquires one short lock to snapshot the
    events dict, then calls Event.set() on each. Story 011 / Section C.
    """
    with _rearm_fire_now_lock:
        events = list(_rearm_fire_now.values())
    for ev in events:
        ev.set()


def _rearm_delay(cadence_idx: int) -> int:
    """Effective re-arm cadence delay for the given index. Honors
    BRIDGE_REARM_INITIAL_INTERVAL_SEC env override for test-time
    cadence compression — when set, every step uses that single value.
    """
    if REARM_INITIAL_INTERVAL_SEC_OVERRIDE:
        try:
            return max(1, int(REARM_INITIAL_INTERVAL_SEC_OVERRIDE))
        except ValueError:
            pass
    return REARM_CADENCE_SEC[min(cadence_idx, len(REARM_CADENCE_SEC) - 1)]


# Two-property match for the gh-webhook extension's persistent webhook on the
# repo. The extension always names its webhook "cli" and points it at this
# fixed forwarder URL. Matching both fields prevents false-positive deletion
# of any user-created webhook that happens to be named "cli".
_GH_WEBHOOK_NAME = "cli"
_GH_WEBHOOK_FORWARDER_URL = "https://webhook-forwarder.github.com/hook"


def _cleanup_stale_webhook(bridge_id: str, repo: str) -> None:
    """Delete any stale `gh webhook forward`-owned webhook on `repo`.

    Root-cause fix for the v2.18.0 flap pattern: `gh webhook forward` always
    tries to create a webhook named "cli" on the target repo. If a "cli"
    hook already exists from a prior bridge spawn that exited without
    cleanup, GitHub returns HTTP 422 "Hook already exists" and the gh
    extension prints USAGE/HELP TEXT to stderr, then exits non-zero. The
    bridge supervisor sees death, retries 3×, falls to polling-only.

    Pre-spawn cleanup deletes any stale "cli"-named webhook whose
    config.url matches the gh-webhook forwarder URL. Two-property match
    (name AND url) makes false-positive deletion of a user-created
    webhook essentially impossible — the gh-webhook extension is the only
    thing that creates this exact pair.

    Failures (network, auth, missing gh) are logged and swallowed; the
    spawn attempt that follows surfaces the real error if cleanup didn't
    help.
    """
    try:
        proc = subprocess.run(
            ["gh", "api", f"repos/{repo}/hooks"],
            capture_output=True,
            text=True,
            check=False,
        )
    except (subprocess.SubprocessError, FileNotFoundError) as exc:
        _emit(
            bridge_id,
            "bridge-status",
            {"state": "armed", "reason": f"webhook cleanup list failed for {repo}: {exc}"},
        )
        return

    if proc.returncode != 0:
        _emit(
            bridge_id,
            "bridge-status",
            {"state": "armed", "reason": f"webhook cleanup list non-zero for {repo}: {proc.stderr.strip()[:200]}"},
        )
        return

    try:
        hooks = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError as exc:
        _emit(
            bridge_id,
            "bridge-status",
            {"state": "armed", "reason": f"webhook cleanup parse failed for {repo}: {exc}"},
        )
        return

    if not isinstance(hooks, list):
        return

    deleted = 0
    for hook in hooks:
        if not isinstance(hook, dict):
            continue
        name = hook.get("name")
        config = hook.get("config") or {}
        url = config.get("url") if isinstance(config, dict) else None
        if name != _GH_WEBHOOK_NAME or url != _GH_WEBHOOK_FORWARDER_URL:
            continue
        hook_id = hook.get("id")
        if not isinstance(hook_id, int):
            continue
        try:
            del_proc = subprocess.run(
                ["gh", "api", f"repos/{repo}/hooks/{hook_id}", "-X", "DELETE"],
                capture_output=True,
                text=True,
                check=False,
            )
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            _emit(
                bridge_id,
                "bridge-status",
                {"state": "armed", "reason": f"webhook cleanup delete failed for {repo} id={hook_id}: {exc}"},
            )
            continue
        if del_proc.returncode == 0:
            deleted += 1
        else:
            _emit(
                bridge_id,
                "bridge-status",
                {"state": "armed", "reason": f"webhook cleanup delete non-zero for {repo} id={hook_id}: {del_proc.stderr.strip()[:200]}"},
            )

    if deleted > 0:
        _emit(
            bridge_id,
            "bridge-status",
            {"state": "armed", "reason": f"cleaned up {deleted} stale cli webhook(s) for {repo} pre-spawn"},
        )


def _run_spawn_cycle(
    bridge_id: str,
    repo: str,
    port: int,
    backoff_sec: int,
    log_path: Path,
    *,
    source: str,
    recovery_timeout: int | None = None,
) -> bool:
    """Run the 3-retry spawn-and-watch cycle for `gh webhook forward`.

    `recovery_timeout` controls the per-spawn watch behavior:
      - `None` (initial-phase contract): wait indefinitely on each
        spawned child. Function only returns `False` (budget exhausted,
        immediate spawn error, or shutdown). Cannot return `True` —
        the initial supervisor must NOT short-circuit while a child is
        still running, or the outer loop would Popen a duplicate.
      - `int` (re-arm-phase contract): wait with that timeout per
        spawned child. If the child stays alive past `recovery_timeout`
        seconds, return `True` to signal recovery; the caller is
        responsible for handing off the still-running child to a
        subsequent supervision cycle.

    `source` is purely for emit prose ("initial" vs "re-arm").
    """
    spawn_count = 0
    while _running and spawn_count < WEBHOOK_FORWARD_RESTART_MAX:
        # Pre-spawn cleanup: remove any stale "cli" webhook from a prior
        # bridge spawn that exited without cleanup. Without this, the gh
        # extension fails with HTTP 422 + prints help-text to stderr.
        _cleanup_stale_webhook(bridge_id, repo)
        try:
            child = subprocess.Popen(
                [
                    "gh", "webhook", "forward",
                    "--repo", repo,
                    "--events", WEBHOOK_EVENTS,
                    "--url", f"http://localhost:{port}/webhook",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            _emit_with_stderr(
                bridge_id, repo, "degraded",
                f"forwarder spawn failed for {repo} ({source}): {exc}",
            )
            return False
        with _forwarder_children_lock:
            _forwarder_children.append(child)
        threading.Thread(
            target=_drain_forwarder_stderr,
            args=(repo, child, log_path),
            daemon=True,
        ).start()
        _emit(
            bridge_id,
            "bridge-status",
            {"state": "armed", "reason": f"webhook forwarder up: {repo}"},
        )
        try:
            if recovery_timeout is None:
                # Initial phase: wait until child dies (no recovery short-circuit).
                child.wait()
            else:
                # Re-arm phase: short-circuit recovery if child stays up.
                child.wait(timeout=recovery_timeout)
        except subprocess.TimeoutExpired:
            # Re-arm-phase only — child is still alive, declare recovery.
            return True
        except KeyboardInterrupt:
            return False
        with _forwarder_children_lock:
            try:
                _forwarder_children.remove(child)
            except ValueError:
                pass
        if not _running:
            return False
        spawn_count += 1
        _emit_with_stderr(
            bridge_id, repo, "degraded",
            f"forwarder died for {repo} ({source} restart "
            f"{spawn_count}/{WEBHOOK_FORWARD_RESTART_MAX})",
        )
        if spawn_count < WEBHOOK_FORWARD_RESTART_MAX:
            time.sleep(backoff_sec)
    return False


def _forwarder_supervisor(
    bridge_id: str,
    repo: str,
    port: int,
    backoff_sec: int = WEBHOOK_FORWARD_RESTART_BACKOFF_SEC,
    cursor_root: Path | None = None,
) -> None:
    """Spawn `gh webhook forward` for `repo`, restart up to N times, then
    if budget exhausts transition to polling-only AND start the re-arm
    timer phase. When recovery declares
    (forwarder up ≥ REARM_RECOVERY_THRESHOLD_SEC), repo is removed from
    _polling_only and the supervisor re-enters the initial spawn loop —
    so a future death restarts the 3-retry budget identically to a fresh
    M-startup spawn.

    Stderr is captured into a per-repo deque + log file; degraded /
    recovered emits include `last_stderr`.
    """
    log_path = _forwarder_log_path(cursor_root, repo)
    while _running:
        # === Initial / regular spawn cycle ===
        # recovery_timeout=None: child.wait() blocks until death (no
        # short-circuit). Function returns False only — never True —
        # so the outer while-loop will not re-Popen while a child is
        # still alive. Critical to avoid the double-spawn bug PP found.
        _run_spawn_cycle(
            bridge_id, repo, port, backoff_sec, log_path,
            source="initial", recovery_timeout=None,
        )
        if not _running:
            return
        # 3-retry budget exhausted — transition to polling-only.
        with _polling_only_lock:
            _polling_only.add(repo)
        _emit_with_stderr(
            bridge_id, repo, "degraded",
            f"forwarder for {repo} exhausted retries — polling-only for this repo",
        )

        # === Re-arm phase ===
        fire_now = threading.Event()
        with _rearm_fire_now_lock:
            _rearm_fire_now[repo] = fire_now
        cadence_idx = 0
        rearm_recovered = False
        while _running:
            delay = _rearm_delay(cadence_idx)
            fire_now.wait(timeout=delay)
            fire_now.clear()
            if not _running:
                break
            if not _probe_network(bridge_id, repo):
                cadence_idx += 1
                continue
            rearm_recovered = _run_spawn_cycle(
                bridge_id, repo, port, backoff_sec, log_path,
                source="re-arm",
                recovery_timeout=REARM_RECOVERY_THRESHOLD_SEC,
            )
            if not _running:
                break
            if rearm_recovered:
                with _polling_only_lock:
                    _polling_only.discard(repo)
                payload: dict = {"state": "armed", "reason": f"recovered: {repo}"}
                extra = _last_stderr_payload(repo)
                if extra:
                    payload.update(extra)
                _emit(bridge_id, "bridge-status", payload)
                with _rearm_fire_now_lock:
                    _rearm_fire_now.pop(repo, None)
                break  # exit re-arm phase, fall back to outer initial loop
            cadence_idx += 1

        if not rearm_recovered:
            # Loop broke because _running went False — clean exit.
            with _rearm_fire_now_lock:
                _rearm_fire_now.pop(repo, None)
            return
        # rearm_recovered: outer while loop will re-enter the initial
        # spawn cycle so subsequent deaths get a fresh 3-retry budget.


def _forwarder_log_path(cursor_root: Path | None, repo: str) -> Path:
    """Per-repo forwarder stderr log path. Falls back to /tmp if
    cursor_root isn't provided (shouldn't happen in normal operation).
    """
    if cursor_root is None:
        return Path("/tmp") / f"forwarder.{_slug(repo)}.log"
    return cursor_root / f"forwarder.{_slug(repo)}.log"


def _signal_forwarders(sig: int) -> None:
    """Send `sig` to every live forwarder child without waiting. Safe to
    call from a signal handler; does not race with the supervisor's own
    `child.wait()` because we never call wait/poll here.
    """
    with _forwarder_children_lock:
        children = list(_forwarder_children)
    for child in children:
        try:
            os.kill(child.pid, sig)
        except (ProcessLookupError, OSError):
            pass


def _terminate_forwarders_blocking() -> None:
    """Called from the main thread at shutdown after the polling loop
    has exited. SIGTERM, give 5s, SIGKILL. The supervisor threads are
    daemons — if they're still blocked on child.wait() at process exit,
    Python tears them down with the interpreter.
    """
    _signal_forwarders(signal.SIGTERM)
    deadline = time.time() + 5
    while time.time() < deadline:
        with _forwarder_children_lock:
            alive = [c for c in _forwarder_children if c.poll() is None]
        if not alive:
            return
        time.sleep(0.1)
    _signal_forwarders(signal.SIGKILL)


def _on_signal(_signum, _frame):
    global _running
    _running = False
    # Just signal the children; do NOT wait. Waiting from a signal
    # handler races with the supervisor's child.wait() on the same PID
    # and can deadlock both threads.
    _signal_forwarders(signal.SIGTERM)


def _sleep_responsive(total_sec: int) -> None:
    slept = 0.0
    while _running and slept < total_sec:
        chunk = min(0.25, total_sec - slept)
        time.sleep(chunk)
        slept += chunk


def main() -> int:
    parser = argparse.ArgumentParser(description="WOW GitHub PR bridge.")
    parser.add_argument("--config", required=True, help="path to config.json")
    args = parser.parse_args()

    config_path = Path(args.config)
    config = json.loads(config_path.read_text())
    port = int(config.get("port", 47823))
    repos = list(config.get("repos", []))
    polling_interval = int(
        config.get("polling_interval_sec", DEFAULT_POLLING_INTERVAL_SEC)
    )
    safety_net_interval = int(
        config.get(
            "webhook_safety_net_interval_sec",
            DEFAULT_WEBHOOK_SAFETY_NET_INTERVAL_SEC,
        )
    )
    requested_mode = (config.get("mode") or "polling").lower()
    forwarder_backoff = int(
        config.get(
            "webhook_forwarder_restart_backoff_sec",
            WEBHOOK_FORWARD_RESTART_BACKOFF_SEC,
        )
    )

    bridge_id = f"github-bridge-{port}"
    cursor_root = config_path.parent

    # Bridge PID file. M reads this to send
    # SIGUSR1 on user-presence triggers. Crash leaves the file behind;
    # next startup overwrites. Cleaned up on clean shutdown below.
    pid_file_path = cursor_root / BRIDGE_PID_FILENAME
    try:
        pid_file_path.write_text(f"{os.getpid()}\n")
    except OSError as exc:
        sys.stderr.write(f"[pid-file] write failed: {exc}\n")

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    # SIGUSR1 — user-presence fast-path for re-arm.
    # POSIX-only; guard for Windows where SIGUSR1 doesn't exist.
    if hasattr(signal, "SIGUSR1"):
        signal.signal(signal.SIGUSR1, _on_user_presence)

    # Mode resolution: webhook mode requires the cli/gh-webhook extension
    # AND admin on each repo. If the extension is missing, force polling
    # for everything; if a specific repo lacks admin, force polling for
    # just that repo.
    effective_mode = requested_mode
    if requested_mode == "webhook":
        if not _check_webhook_extension():
            _emit(
                bridge_id,
                "bridge-status",
                {
                    "state": "degraded",
                    "reason": (
                        "gh-webhook extension missing; install via "
                        "'gh extension install cli/gh-webhook' — "
                        "falling back to polling"
                    ),
                },
            )
            effective_mode = "polling"
        else:
            for repo in repos:
                if not _check_admin(repo):
                    _emit(
                        bridge_id,
                        "bridge-status",
                        {
                            "state": "degraded",
                            "reason": (
                                f"no admin on {repo} — polling-only "
                                "for this repo"
                            ),
                        },
                    )
                    with _polling_only_lock:
                        _polling_only.add(repo)

    webhook_server: ThreadingHTTPServer | None = None
    if effective_mode == "webhook":
        try:
            webhook_server = _start_webhook_listener(
                bridge_id, port, cursor_root,
            )
        except OSError as exc:
            _emit(
                bridge_id,
                "bridge-status",
                {
                    "state": "degraded",
                    "reason": (
                        f"could not bind 127.0.0.1:{port} ({exc}) — "
                        "falling back to polling"
                    ),
                },
            )
            effective_mode = "polling"
        else:
            for repo in repos:
                with _polling_only_lock:
                    skip = repo in _polling_only
                if skip:
                    continue
                threading.Thread(
                    target=_forwarder_supervisor,
                    args=(bridge_id, repo, port, forwarder_backoff, cursor_root),
                    daemon=True,
                ).start()

    interval = (
        safety_net_interval if effective_mode == "webhook" else polling_interval
    )

    _emit(
        bridge_id,
        "bridge-status",
        {
            "state": "armed",
            "reason": (
                f"watching {','.join(repos)} via {effective_mode} "
                f"(polling cadence {interval}s)"
                if repos
                else "no repos configured"
            ),
        },
    )

    failure_counts = {repo: 0 for repo in repos}
    degraded = {repo: False for repo in repos}

    while _running:
        for repo in repos:
            if not _running:
                break
            try:
                prs = _gh_api(f"/repos/{repo}/pulls?state=all&per_page=50")
                if degraded.get(repo):
                    _emit(
                        bridge_id,
                        "bridge-status",
                        {"state": "armed", "reason": f"recovered: {repo}"},
                    )
                    degraded[repo] = False
                failure_counts[repo] = 0
            except Exception as exc:
                failure_counts[repo] = failure_counts.get(repo, 0) + 1
                if (
                    failure_counts[repo] >= DEGRADATION_THRESHOLD
                    and not degraded.get(repo)
                ):
                    _emit(
                        bridge_id,
                        "bridge-status",
                        {
                            "state": "degraded",
                            "reason": f"{repo}: {str(exc)[:200]}",
                        },
                    )
                    degraded[repo] = True
                continue

            for pr in prs:
                if not _running:
                    break
                num = pr.get("number")
                if num is None:
                    continue
                current = _state_from_pr(pr)
                pr_url = pr.get("html_url") or ""
                head_sha = ((pr.get("head") or {}).get("sha")) or ""
                actor: str | None = None
                if current == "merged":
                    merged_by = pr.get("merged_by") or {}
                    actor = merged_by.get("login")
                elif current == "closed":
                    closed_by = pr.get("closed_by") or {}
                    actor = closed_by.get("login")

                lock = _get_pr_lock(repo, num)
                with lock:
                    cursor_path = cursor_root / _slug(repo) / f"pr-{num}.cursor"
                    prior = _read_cursor(cursor_path)
                    cursor: dict = dict(prior) if prior is not None else {}

                    populating = "state" not in cursor

                    _process_pr_state(
                        bridge_id, repo, num, current, cursor, pr_url, actor,
                    )
                    try:
                        _emit_review_events(
                            bridge_id, repo, num, cursor, pr_url,
                            populating=populating,
                        )
                    except Exception:
                        pass
                    try:
                        _emit_comment_events(
                            bridge_id, repo, num, cursor, pr_url,
                            populating=populating,
                        )
                    except Exception:
                        pass
                    try:
                        _emit_ci_events(bridge_id, repo, num, head_sha, cursor)
                    except Exception:
                        pass

                    cursor["last_seen_ts"] = _now_iso()
                    _write_cursor(cursor_path, cursor)

        if not _running:
            break
        _sleep_responsive(interval)

    if webhook_server is not None:
        try:
            webhook_server.shutdown()
            webhook_server.server_close()
        except OSError:
            pass
    _terminate_forwarders_blocking()

    # Wake any re-arm timers waiting on fire_now so they exit promptly.
    with _rearm_fire_now_lock:
        for ev in _rearm_fire_now.values():
            ev.set()

    _emit(
        bridge_id,
        "bridge-status",
        {"state": "stopped", "reason": "received termination signal"},
    )

    # PID file cleanup. Best-effort.
    try:
        pid_file_path.unlink()
    except (OSError, FileNotFoundError):
        pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
