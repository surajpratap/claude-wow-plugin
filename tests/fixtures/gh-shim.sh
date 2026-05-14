#!/usr/bin/env bash
# Test fixture — fake `gh` CLI.
#
# Driven by env vars set by the calling test. The shim recognises `gh api`
# (the bridge's poll calls) and `gh pr comment` (PP's triage authority).
#
# `gh api <path>`:
#   The shim is URL-aware. The path arg is matched (in order) against:
#     - `*/reviews` (suffix)      → uses WOW_GH_REVIEWS_LIST/_FILE
#     - `*/comments` (suffix)     → uses WOW_GH_COMMENTS_LIST/_FILE
#     - `*/pulls?...` or `*/pulls` → uses WOW_GH_RESPONSE_LIST/_FILE
#                                    (the main PR-list call)
#     - any other                 → uses WOW_GH_RESPONSE_LIST/_FILE
#                                    (Story 005 backward compat)
#   Default for any unmatched/empty path: empty JSON array (`[]`).
#
#   Per-category env vars:
#     WOW_GH_RESPONSE_FILE       — single canned JSON for the PR-list call.
#     WOW_GH_RESPONSE_LIST       — file of canned-response paths, one per line.
#     WOW_GH_REVIEWS_FILE        — single canned JSON for `*/reviews`.
#     WOW_GH_REVIEWS_LIST        — file of canned-response paths for `*/reviews`.
#     WOW_GH_COMMENTS_FILE       — single canned JSON for `*/comments`.
#     WOW_GH_COMMENTS_LIST       — file of canned-response paths for `*/comments`.
#     WOW_GH_CHECK_SUITES_FILE   — single canned JSON for `*/check-suites`.
#                                  The file's content is the wrapper-shape
#                                  GitHub API returns: `{check_suites: [...]}`.
#     WOW_GH_CHECK_SUITES_LIST   — file of canned-response paths for
#                                  `*/check-suites`.
#     WOW_GH_COUNTER_FILE        — counter for the PR-list LIST mode.
#     WOW_GH_REVIEWS_COUNTER     — counter for the reviews LIST mode.
#     WOW_GH_COMMENTS_COUNTER    — counter for the comments LIST mode.
#     WOW_GH_CHECK_SUITES_COUNTER — counter for the check-suites LIST mode.
#     WOW_GH_FAIL                — every `gh api` call exits 1 with
#                                  "auth required" (degraded path).
#     WOW_GH_FAIL_PATH_GLOB      — `gh api` calls whose api path matches
#                                  this glob (bash case-pattern syntax)
#                                  exit 1 instead of dispatching. Lets a
#                                  multi-repo test fail one repo while the
#                                  other succeeds.
#
# `gh pr comment <N> --body <text>` (PP authority introduced in v2.4.0):
#   Records the call to WOW_GH_PR_COMMENT_LOG (default
#   /tmp/wow-gh-pr-comment-log-<pid>.jsonl) as one JSON line per call:
#   {ts, pr, args}. Exits 0.
#
# `gh extension list` (introduced in v2.5.0 for webhook-mode detection):
#   Prints WOW_GH_EXTENSION_LIST_OUTPUT verbatim (default empty — no
#   extensions installed → bridge falls back to polling-only). To
#   simulate cli/gh-webhook installed, set the env to a string
#   containing "gh-webhook" (e.g. "github.com/cli/gh-webhook gh-webhook v0.0.1").
#
# `gh api /repos/<owner>/<name>` (no trailing path) is matched by the
# `*/repos/<o>/<n>` glob in api dispatch and uses WOW_GH_REPO_META_FILE
# (default {"permissions":{"admin":true}}). Lets webhook-mode tests
# control whether the gh-auth user has admin on a repo.
#
# `gh webhook forward ...` (introduced in v2.5.0):
#   exec's WOW_GH_WEBHOOK_FORWARD_BIN if set; otherwise sleeps until
#   killed (so the bridge can spawn / kill it without it actually
#   contacting GitHub).
#
# Anything else exits 1.

set -u

dispatch_list_or_file() {
  # $1: list env var name; $2: file env var name; $3: counter env var name
  local list_var="$1"
  local file_var="$2"
  local counter_var="$3"
  local list="${!list_var:-}"
  local file="${!file_var:-}"
  local counter="${!counter_var:-}"

  if [ -n "$list" ]; then
    [ -z "$counter" ] && counter="/tmp/wow-gh-counter-${list_var}-$$"
    local n
    n=$(cat "$counter" 2>/dev/null || echo 0)
    local next=$((n + 1))
    printf '%d\n' "$next" > "$counter"
    local response_file
    response_file=$(sed -n "${next}p" "$list" || true)
    if [ -n "$response_file" ] && [ -f "$response_file" ]; then
      cat "$response_file"
      return 0
    fi
    echo '[]'
    return 0
  fi

  if [ -n "$file" ] && [ -f "$file" ]; then
    cat "$file"
    return 0
  fi

  echo '[]'
}

if [ "${1:-}" = "api" ]; then
  if [ -n "${WOW_GH_FAIL:-}" ]; then
    echo "auth required" >&2
    exit 1
  fi
  api_path="${2:-}"
  if [ -n "${WOW_GH_FAIL_PATH_GLOB:-}" ]; then
    case "$api_path" in
      ${WOW_GH_FAIL_PATH_GLOB})
        echo "rate limited" >&2
        exit 1
        ;;
    esac
  fi
  case "$api_path" in
    */reviews|*/reviews\?*)
      dispatch_list_or_file WOW_GH_REVIEWS_LIST WOW_GH_REVIEWS_FILE WOW_GH_REVIEWS_COUNTER
      exit 0
      ;;
    */comments|*/comments\?*)
      dispatch_list_or_file WOW_GH_COMMENTS_LIST WOW_GH_COMMENTS_FILE WOW_GH_COMMENTS_COUNTER
      exit 0
      ;;
    */check-suites|*/check-suites\?*)
      dispatch_list_or_file WOW_GH_CHECK_SUITES_LIST WOW_GH_CHECK_SUITES_FILE WOW_GH_CHECK_SUITES_COUNTER
      exit 0
      ;;
    rate_limit|/rate_limit)
      # Story 011 / Section B: bridge re-arm probe.
      # WOW_GH_RATE_LIMIT_FAIL set → exit 1 (probe fails); else default success.
      if [ -n "${WOW_GH_RATE_LIMIT_FAIL:-}" ]; then
        echo "rate_limit: synthetic failure" >&2
        exit 1
      fi
      echo '{"resources":{"core":{"limit":5000,"remaining":5000,"reset":0}}}'
      exit 0
      ;;
    */pulls\?*|*/pulls)
      dispatch_list_or_file WOW_GH_RESPONSE_LIST WOW_GH_RESPONSE_FILE WOW_GH_COUNTER_FILE
      exit 0
      ;;
    /repos/*/*)
      # /repos/<o>/<n> with no trailing path — repo metadata.
      if [ -n "${WOW_GH_REPO_META_FILE:-}" ] && [ -f "${WOW_GH_REPO_META_FILE}" ]; then
        cat "${WOW_GH_REPO_META_FILE}"
      else
        echo '{"permissions":{"admin":true}}'
      fi
      exit 0
      ;;
    *)
      dispatch_list_or_file WOW_GH_RESPONSE_LIST WOW_GH_RESPONSE_FILE WOW_GH_COUNTER_FILE
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "extension" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' "${WOW_GH_EXTENSION_LIST_OUTPUT:-}"
  exit 0
fi

if [ "${1:-}" = "webhook" ] && [ "${2:-}" = "forward" ]; then
  if [ -n "${WOW_GH_WEBHOOK_FORWARD_BIN:-}" ] && [ -x "${WOW_GH_WEBHOOK_FORWARD_BIN}" ]; then
    exec "${WOW_GH_WEBHOOK_FORWARD_BIN}" "$@"
  fi
  # Default: become a long sleep so the bridge can kill us cleanly via
  # SIGTERM (the default disposition of SIGTERM on `sleep` is to
  # terminate). `exec` replaces the bash shell — without it, SIGTERM
  # would interrupt bash but leave its `sleep` child orphaned, since
  # bash defers signal handling until the foreground command finishes.
  exec sleep 86400
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
  log="${WOW_GH_PR_COMMENT_LOG:-/tmp/wow-gh-pr-comment-log-$$.jsonl}"
  mkdir -p "$(dirname "$log")"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  pr="${3:-}"
  shift 3 || true
  args_json=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  printf '{"ts":"%s","pr":"%s","args":%s}\n' "$ts" "$pr" "$args_json" >> "$log"
  exit 0
fi

echo "[gh shim] unsupported: $*" >&2
exit 1
