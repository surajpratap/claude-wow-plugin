#!/usr/bin/env bash
# Regression test for Story 009 / Defect 1.
#
# Reproduces the exact PR #7 scenario:
#   1. Bridge polls a PR; review/comment lists are empty; cursor gets
#      `state` set but no last_*_id fields.
#   2. A webhook delivery for a pull_request_review_comment arrives.
#   3. PRE-FIX (v2.6.0): the bridge silently swallowed the event because
#      "last_review_comment_id not in cursor" (or the old single
#      "last_comment_id not in cursor") was treated as "still populating".
#   4. POST-FIX (v2.7.0): webhook deliveries always emit (populating=False
#      hardcoded in webhook branches) — assert exactly one pr-comment
#      event with kind=review_thread.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$REPO_ROOT/bridge/github/run.py"
SHIM="$REPO_ROOT/tests/fixtures/gh-shim.sh"

if [ ! -f "$BRIDGE" ] || [ ! -f "$SHIM" ]; then
  echo "FATAL: missing bridge or shim" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "FATAL: jq + python3 + curl required" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

case_empty_pr_then_review_comment() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/test-repo"
  cp "$SHIM" "$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  printf '[]\n' > "$tmp/empty-pulls.json"

  # Simulate a state-only cursor: PR has been polled once, both review
  # and comment endpoints returned empty lists, so only `state` is set.
  cat > "$tmp/test-repo/pr-42.cursor" <<'EOF'
{"state":"ready_for_review","last_seen_ts":"2026-04-30T13:00:00Z"}
EOF

  local port; port=$(pick_port)
  cat > "$tmp/config.json" <<EOF
{"port": $port, "repos": ["test/repo"], "polling_interval_sec": 60, "mode": "webhook", "webhook_safety_net_interval_sec": 60, "webhook_forwarder_restart_backoff_sec": 1}
EOF

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/empty-pulls.json" \
    WOW_GH_EXTENSION_LIST_OUTPUT="github.com/cli/gh-webhook gh-webhook v0.0.1" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 1.5

  curl -sS -X POST "http://127.0.0.1:$port/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: pull_request_review_comment" \
    --data '{"repository":{"full_name":"test/repo"},"pull_request":{"number":42,"html_url":"https://example.com/pr/42"},"comment":{"id":3168527910,"body":"please align this","html_url":"https://example.com/pr/42#discussion_r3168527910","user":{"login":"alice"}}}' >/dev/null
  sleep 0.5

  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(grep -c '"type":"pr-comment"' "$tmp/out.jsonl" 2>/dev/null || echo 0)
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "empty-PR-then-review-comment: pr-comment count (regression — was 0 pre-fix)" 1 "$n"

  local event; event=$(grep '"type":"pr-comment"' "$tmp/out.jsonl" 2>/dev/null | head -1)
  if [ -n "$event" ]; then
    assert_eq "empty-PR-then-review-comment: emitted kind" "review_thread" "$(printf '%s' "$event" | jq -r '.payload | fromjson | .kind')"
    assert_eq "empty-PR-then-review-comment: emitted author" "alice" "$(printf '%s' "$event" | jq -r '.payload | fromjson | .author')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("empty-PR-then-review-comment: missing pr-comment event")
  fi

  if [ -f "$tmp/test-repo/pr-42.cursor" ]; then
    local lrc; lrc=$(jq -r '.last_review_comment_id // empty' "$tmp/test-repo/pr-42.cursor")
    assert_eq "empty-PR-then-review-comment: cursor last_review_comment_id" "3168527910" "$lrc"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("empty-PR-then-review-comment: cursor file vanished")
  fi

  rm -rf "$tmp"
}

case_empty_pr_then_review_comment

echo
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "failed cases:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  - $c"
  done
  exit 1
fi
exit 0
