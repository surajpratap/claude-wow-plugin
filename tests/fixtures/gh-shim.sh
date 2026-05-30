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
#     WOW_GH_CALL_LOG            — append each resolved `gh api` <path> (one per
#                                  line) so tests can assert call counts/order.
#     WOW_GH_PR_DETAIL_FILE/_LIST/_COUNTER — canned response for a single-PR
#                                  `*/pulls/<num>` detail fetch (story 164's
#                                  disappearance->terminal confirmation).
#
#   Shared 165/166/167 harness — leading `-i` and repeated `-H <val>` flags are
#   skipped before path dispatch (a `-H If-None-Match:` request logs an
#   `IF-NONE-MATCH<TAB><path>` call-log line; bare/non-conditional calls log the
#   plain path). With `-i`, response headers precede the body, and a `gh api`
#   emitting an HTTP status >299 (incl 304 / the 599 fail-closed) EXITS NONZERO,
#   modeling real `gh`:
#     WOW_GH_STATUS              — single HTTP status (default 200).
#     WOW_GH_STATUS_LIST         — sequenced status, one per line. Its counter is
#                                  WOW_GH_STATUS_COUNTER (explicit) OR a per-endpoint
#                                  counter under WOW_GH_STATUS_COUNTER_DIR (stable
#                                  across `gh api` subprocesses -> a real 200->304
#                                  sequence). Neither set -> FAIL-CLOSED (599 +
#                                  nonzero exit), never a hollow $$-per-process counter.
#     WOW_GH_ETAG / WOW_GH_RETRY_AFTER / WOW_GH_RATELIMIT_REMAINING — header vals.
#     WOW_GH_CHECK_SUITES_STATUS — story 167: per-endpoint status override for
#                                  `*/check-suites*` calls only (so a sub-call can
#                                  429 while the list/reviews succeed — the shared
#                                  STATUS_LIST counter can't express that). Applied
#                                  before the STATUS_LIST block; inert without it.
#     WOW_GH_RATE_LIMIT_BODY     — story 167: a file whose contents replace the
#                                  hardcoded healthy `rate_limit` probe body (drives
#                                  the proactive low-`remaining` widen path). Inert
#                                  without the env.
#     WOW_GH_MALFORMED_HEADERS   — emit unparseable `-i` output (drives the bridge's
#                                  parse-ambiguity bare-GET fallback).
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

emit_headers() {
  # Only when `gh api -i` was requested. Stories 165/167 read these. Sets the
  # shared RC=1 for any status >299 (incl 304/599) so the dispatch exits nonzero,
  # modeling real `gh`. WOW_GH_MALFORMED_HEADERS emits unparseable output (drives
  # the bridge's parse-ambiguity bare-GET fallback). Status is sequenced via
  # WOW_GH_STATUS_LIST so one process can drive a 200 -> 304 sequence (AC4(ii)).
  [ -n "${want_headers:-}" ] || return 0
  if [ -n "${WOW_GH_MALFORMED_HEADERS:-}" ]; then
    printf 'MALFORMED-NO-STATUS-LINE\n'   # no blank separator -> _parse_gh_include None
    return 0
  fi
  local status="${WOW_GH_STATUS:-200}"
  # Story 167: per-endpoint status override so a LATER sub-call can fail while
  # the list/reviews succeed (the shared WOW_GH_STATUS_LIST sequence can't —
  # both endpoints read the same counter). Inert without the env.
  case "${api_path:-}" in
    */check-suites*) [ -n "${WOW_GH_CHECK_SUITES_STATUS:-}" ] && status="$WOW_GH_CHECK_SUITES_STATUS" ;;
  esac
  # TEST-DESIGN PITFALL (why this matters, non-obvious): WOW_GH_STATUS_LIST is a
  # SINGLE sequence consumed by EVERY endpoint (list AND each sub-call: reviews,
  # comments, check-suites, pulls/<n>) — but each endpoint has its OWN per-path
  # counter below, so they advance INDEPENDENTLY. A shared `200 429 200 ...`
  # therefore makes a sub-call hit its 429 a cycle AFTER the list does; with the
  # bridge's exponential backoff, that staggered re-throttle can push a recovery
  # (or any discriminating) cycle PAST a test's kill window — a hollow/unreachable
  # assertion. To exercise just the list-call lever, drive an EMPTY open list (no
  # PRs -> no sub-call fetches; story 167 cases a/b). To fail ONE sub-call while
  # others succeed, use the per-endpoint WOW_GH_CHECK_SUITES_STATUS knob (case f),
  # NOT the shared list.
  if [ -n "${WOW_GH_STATUS_LIST:-}" ]; then
    local sc
    if [ -n "${WOW_GH_STATUS_COUNTER:-}" ]; then
      sc="$WOW_GH_STATUS_COUNTER"
    elif [ -n "${WOW_GH_STATUS_COUNTER_DIR:-}" ]; then
      # per-(repo,endpoint) auto-advance: a STABLE path from api_path, shared
      # across `gh api` subprocesses (NOT $$, fresh per call -> FINDING-45).
      sc="${WOW_GH_STATUS_COUNTER_DIR}/.wow-gh-status-$(printf '%s' "${api_path:-}" | tr -c 'A-Za-z0-9' '_')"
    else
      # FAIL-CLOSED: no stable counter -> the sequence would be hollow. Refuse
      # loudly (599 + nonzero exit) so a 200->304 assertion cannot silently pass.
      echo "gh-shim: WOW_GH_STATUS_LIST needs WOW_GH_STATUS_COUNTER or WOW_GH_STATUS_COUNTER_DIR (else hollow)" >&2
      printf 'HTTP/2.0 599\r\n\r\n'
      RC=1
      return 0
    fi
    local n; n=$(cat "$sc" 2>/dev/null || echo 0); local next=$((n + 1))
    printf '%d\n' "$next" > "$sc"
    local s; s=$(sed -n "${next}p" "$WOW_GH_STATUS_LIST" 2>/dev/null)
    [ -n "$s" ] && status="$s"
  fi
  printf 'HTTP/2.0 %s\r\n' "$status"
  if [ "$status" -gt 299 ] 2>/dev/null; then RC=1; fi
  [ -n "${WOW_GH_ETAG:-}" ]                && printf 'ETag: %s\r\n' "$WOW_GH_ETAG"
  [ -n "${WOW_GH_RETRY_AFTER:-}" ]         && printf 'Retry-After: %s\r\n' "$WOW_GH_RETRY_AFTER"
  [ -n "${WOW_GH_RATELIMIT_REMAINING:-}" ] && printf 'X-RateLimit-Remaining: %s\r\n' "$WOW_GH_RATELIMIT_REMAINING"
  printf '\r\n'
}

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
  # Skip leading flags so `gh api [-i] [-H <val>]... <path>` dispatches by path.
  # `-i` requests response headers; `-H <val>` is a request header (skip the pair).
  shift   # drop "api"; remaining args are flags + the path
  want_headers=""; cond=""; RC=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -i) want_headers=1; shift ;;
      -H) shift
          if [ "$#" -gt 0 ]; then
            case "$1" in [Ii]f-[Nn]one-[Mm]atch:*) cond=1 ;; esac
            shift
          fi ;;
      --) shift; break ;;
      -*) shift ;;
      *)  break ;;
    esac
  done
  api_path="${1:-}"
  if [ -n "${WOW_GH_CALL_LOG:-}" ]; then
    # ONE line per call so the test distinguishes a conditional request from a
    # bare full-GET: conditional (If-None-Match) -> `IF-NONE-MATCH<TAB><path>`, else plain.
    if [ -n "$cond" ]; then
      printf 'IF-NONE-MATCH\t%s\n' "$api_path" >> "$WOW_GH_CALL_LOG"
    else
      printf '%s\n' "$api_path" >> "$WOW_GH_CALL_LOG"
    fi
  fi
  if [ -n "${WOW_GH_FAIL_PATH_GLOB:-}" ]; then
    # shellcheck disable=SC2254 # glob expansion is intentional here — the
    # var holds a literal case-pattern that selects which API path to fail.
    case "$api_path" in
      ${WOW_GH_FAIL_PATH_GLOB})
        echo "rate limited" >&2
        exit 1
        ;;
    esac
  fi
  emit_headers
  case "$api_path" in
    */reviews|*/reviews\?*)
      dispatch_list_or_file WOW_GH_REVIEWS_LIST WOW_GH_REVIEWS_FILE WOW_GH_REVIEWS_COUNTER
      exit "$RC"
      ;;
    */comments|*/comments\?*)
      dispatch_list_or_file WOW_GH_COMMENTS_LIST WOW_GH_COMMENTS_FILE WOW_GH_COMMENTS_COUNTER
      exit "$RC"
      ;;
    */check-suites|*/check-suites\?*)
      dispatch_list_or_file WOW_GH_CHECK_SUITES_LIST WOW_GH_CHECK_SUITES_FILE WOW_GH_CHECK_SUITES_COUNTER
      exit "$RC"
      ;;
    rate_limit|/rate_limit)
      # Story 011 / Section B: bridge re-arm probe.
      # WOW_GH_RATE_LIMIT_FAIL set → exit 1 (probe fails); else default success.
      if [ -n "${WOW_GH_RATE_LIMIT_FAIL:-}" ]; then
        echo "rate_limit: synthetic failure" >&2
        exit 1
      fi
      # Story 167: honor a canned rate_limit body file (for the proactive
      # low-`remaining` case) before the hardcoded healthy default. Inert
      # without the env.
      if [ -n "${WOW_GH_RATE_LIMIT_BODY:-}" ] && [ -f "${WOW_GH_RATE_LIMIT_BODY}" ]; then
        cat "${WOW_GH_RATE_LIMIT_BODY}"
      else
        echo '{"resources":{"core":{"limit":5000,"remaining":5000,"reset":0}}}'
      fi
      exit "$RC"
      ;;
    */pulls/[0-9]*)
      dispatch_list_or_file WOW_GH_PR_DETAIL_LIST WOW_GH_PR_DETAIL_FILE WOW_GH_PR_DETAIL_COUNTER
      exit "$RC"
      ;;
    */pulls\?*|*/pulls)
      dispatch_list_or_file WOW_GH_RESPONSE_LIST WOW_GH_RESPONSE_FILE WOW_GH_COUNTER_FILE
      exit "$RC"
      ;;
    /repos/*/*)
      # /repos/<o>/<n> with no trailing path — repo metadata.
      if [ -n "${WOW_GH_REPO_META_FILE:-}" ] && [ -f "${WOW_GH_REPO_META_FILE}" ]; then
        cat "${WOW_GH_REPO_META_FILE}"
      else
        echo '{"permissions":{"admin":true}}'
      fi
      exit "$RC"
      ;;
    *)
      dispatch_list_or_file WOW_GH_RESPONSE_LIST WOW_GH_RESPONSE_FILE WOW_GH_COUNTER_FILE
      exit "$RC"
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
