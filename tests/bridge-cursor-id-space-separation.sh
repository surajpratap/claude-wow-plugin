#!/usr/bin/env bash
# Regression test for Story 009 / Defect 2.
#
# Reproduces the second PR #7 defect:
#   1. Cursor has `last_issue_comment_id = 9999999999` (high water mark
#      from a recent issue_comment).
#   2. A webhook delivery for a pull_request_review_comment with id =
#      1000000000 arrives (lower than the issue_comment id, but in a
#      different ID space).
#   3. PRE-FIX (v2.6.0): single shared `last_comment_id` field caused
#      the dedup `cid <= prior_max` check to silently drop the lower id.
#   4. POST-FIX (v2.7.0): separate `last_issue_comment_id` and
#      `last_review_comment_id` fields — the lower review_comment id is
#      tracked independently, so the event emits as expected.

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

case_id_space_separation() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/test-repo"
  cp "$SHIM" "$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  printf '[]\n' > "$tmp/empty-pulls.json"

  # Cursor with a high issue_comment ID in its own field; review_comment
  # field absent. Goal: a lower review_comment id should still emit
  # because the two ID spaces are tracked independently.
  cat > "$tmp/test-repo/pr-42.cursor" <<'EOF'
{"state":"ready_for_review","last_issue_comment_id":9999999999,"last_seen_ts":"2026-04-30T13:00:00Z"}
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
    --data '{"repository":{"full_name":"test/repo"},"pull_request":{"number":42,"html_url":"https://example.com/pr/42"},"comment":{"id":1000000000,"body":"inline note","html_url":"https://example.com/pr/42#discussion_r1000000000","user":{"login":"bob"}}}' >/dev/null
  sleep 0.5

  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(grep -c '"type":"pr-comment"' "$tmp/out.jsonl" 2>/dev/null || echo 0)
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "id-space-separation: pr-comment count (regression — was 0 pre-fix)" 1 "$n"

  local event; event=$(grep '"type":"pr-comment"' "$tmp/out.jsonl" 2>/dev/null | head -1)
  if [ -n "$event" ]; then
    assert_eq "id-space-separation: emitted kind" "review_thread" "$(printf '%s' "$event" | jq -r '.payload | fromjson | .kind')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("id-space-separation: missing pr-comment event")
  fi

  if [ -f "$tmp/test-repo/pr-42.cursor" ]; then
    local lrc; lrc=$(jq -r '.last_review_comment_id // empty' "$tmp/test-repo/pr-42.cursor")
    local lic; lic=$(jq -r '.last_issue_comment_id // empty' "$tmp/test-repo/pr-42.cursor")
    assert_eq "id-space-separation: cursor.last_review_comment_id (lower id tracked separately)" "1000000000" "$lrc"
    assert_eq "id-space-separation: cursor.last_issue_comment_id untouched" "9999999999" "$lic"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("id-space-separation: cursor file vanished")
  fi

  rm -rf "$tmp"
}

case_id_space_separation

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
