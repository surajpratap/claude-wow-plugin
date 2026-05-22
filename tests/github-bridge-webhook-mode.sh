#!/usr/bin/env bash
# Verify webhook-mode behaviors of bridge/github/run.py:
#   - When the cli/gh-webhook extension is missing, bridge degrades and
#     falls back to polling-only (no `gh webhook forward` is spawned).
#   - When webhook delivery POSTs to the listener, the bridge processes
#     the event through the same dedup helpers as polling.
#   - Concurrent POSTs for different PRs don't corrupt cursors.
#   - When `gh webhook forward` keeps dying, the supervisor restarts it
#     up to 3 times (with backoff), then forces polling-only.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$REPO_ROOT/bridge/github/run.py"
SHIM="$REPO_ROOT/tests/fixtures/gh-shim.sh"
# Story 144: wait_for_bridge — poll for OUR bridge's `armed` readiness instead
# of a fixed startup sleep (the :55303-class startup race).
# shellcheck source=lib/bridge-port.sh
. "$REPO_ROOT/tests/lib/bridge-port.sh"

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
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

setup_tmp() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cp "$SHIM" "$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  printf '[]\n' > "$tmp/empty-pulls.json"
  printf '%s' "$tmp"
}

# Allocate a free ephemeral port via Python — the kernel picks one we
# know isn't currently bound. The bridge's _BridgeWebhookServer sets
# allow_reuse_address so it can rebind the just-released port (Story
# 010 / backlog 018).
pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# ---------------------------------------------------------------------------
# Case 1: gh-webhook extension missing → bridge degrades, falls back to
# polling. No `gh webhook forward` child is spawned (we can confirm by
# the absence of the WOW_GH_WEBHOOK_FORWARD_BIN sentinel file).
# ---------------------------------------------------------------------------
case_extension_missing() {
  local tmp; tmp="$(setup_tmp)"
  local port; port=$(pick_port)
  cat > "$tmp/config.json" <<EOF
{"port": $port, "repos": ["test/repo"], "polling_interval_sec": 1, "mode": "webhook"}
EOF
  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/empty-pulls.json" \
    WOW_GH_EXTENSION_LIST_OUTPUT="" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  wait_for_bridge "$tmp/out.jsonl" 10 || true   # Story 144: readiness, not fixed sleep
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  # bridge-status: degraded with extension-missing reason should fire.
  local degraded
  degraded=$(grep '"type":"bridge-status"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | select(.state == "degraded") | .reason' | grep -c "gh-webhook extension missing" || echo 0)
  degraded=$(printf '%s' "$degraded" | tr -d '[:space:]')
  if [ "$degraded" -ge 1 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case1: expected degraded bridge-status mentioning extension missing, got $degraded")
  fi

  # Final armed status mode should be polling.
  local armed_polling
  armed_polling=$(grep '"type":"bridge-status"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | select(.state == "armed") | .reason' | grep -c "polling" || echo 0)
  armed_polling=$(printf '%s' "$armed_polling" | tr -d '[:space:]')
  if [ "$armed_polling" -ge 1 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case1: expected armed bridge-status mentioning polling, got $armed_polling")
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 2: webhook delivery → emit. Bridge is in webhook mode with the
# extension present. v2.7.0+ webhook deliveries are ALWAYS live (never
# populate) — both POSTs emit. We send two pull_request_review events
# and expect both to land on stdout in id order.
# ---------------------------------------------------------------------------
case_webhook_emit() {
  local tmp; tmp="$(setup_tmp)"
  local port; port=$(pick_port)
  cat > "$tmp/config.json" <<EOF
{"port": $port, "repos": ["test/repo"], "polling_interval_sec": 60, "mode": "webhook", "webhook_safety_net_interval_sec": 60, "webhook_forwarder_restart_backoff_sec": 1}
EOF

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/empty-pulls.json" \
    WOW_GH_EXTENSION_LIST_OUTPUT="github.com/cli/gh-webhook gh-webhook v0.0.1" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  # Story 144: wait for the bridge to ARM (listener bound) before POSTing —
  # a fixed sleep was too short under load → curl connection-refused (the
  # :55303-class startup race). Readiness, not a fixed sleep.
  wait_for_bridge "$tmp/out.jsonl" 10 || true

  # First POST: emits (webhook always lives) with reviewer=alice, state=commented.
  curl -sS -X POST "http://127.0.0.1:$port/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: pull_request_review" \
    --data '{"repository":{"full_name":"test/repo"},"pull_request":{"number":42,"html_url":"https://example.com/pr/42"},"review":{"id":500,"state":"COMMENTED","body":"first","html_url":"https://example.com/pr/42#review-500","user":{"login":"alice"}}}' >/dev/null
  sleep 0.5

  # Second POST: also emits — reviewer=bob, state=changes_requested.
  curl -sS -X POST "http://127.0.0.1:$port/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: pull_request_review" \
    --data '{"repository":{"full_name":"test/repo"},"pull_request":{"number":42,"html_url":"https://example.com/pr/42"},"review":{"id":600,"state":"CHANGES_REQUESTED","body":"please fix","html_url":"https://example.com/pr/42#review-600","user":{"login":"bob"}}}' >/dev/null
  sleep 0.5

  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(grep -c '"type":"pr-review"' "$tmp/out.jsonl" 2>/dev/null || echo 0)
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case2: pr-review event count from webhook (2; webhook never populates per v2.7.0)" 2 "$n"

  local first; first=$(grep '"type":"pr-review"' "$tmp/out.jsonl" 2>/dev/null | head -1)
  local second; second=$(grep '"type":"pr-review"' "$tmp/out.jsonl" 2>/dev/null | sed -n '2p')
  if [ -n "$first" ]; then
    assert_eq "case2: 1st pr-review reviewer" "alice" "$(printf '%s' "$first" | jq -r '.payload | fromjson | .reviewer')"
    assert_eq "case2: 1st pr-review state" "commented" "$(printf '%s' "$first" | jq -r '.payload | fromjson | .state')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case2: missing 1st pr-review event")
  fi
  if [ -n "$second" ]; then
    assert_eq "case2: 2nd pr-review reviewer" "bob" "$(printf '%s' "$second" | jq -r '.payload | fromjson | .reviewer')"
    assert_eq "case2: 2nd pr-review state" "changes_requested" "$(printf '%s' "$second" | jq -r '.payload | fromjson | .state')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case2: missing 2nd pr-review event")
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 3: concurrent POSTs for different PRs don't corrupt cursors.
# ---------------------------------------------------------------------------
case_concurrent_different_prs() {
  local tmp; tmp="$(setup_tmp)"
  local port; port=$(pick_port)
  cat > "$tmp/config.json" <<EOF
{"port": $port, "repos": ["test/repo"], "polling_interval_sec": 60, "mode": "webhook", "webhook_safety_net_interval_sec": 60, "webhook_forwarder_restart_backoff_sec": 1}
EOF

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/empty-pulls.json" \
    WOW_GH_EXTENSION_LIST_OUTPUT="github.com/cli/gh-webhook gh-webhook v0.0.1" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  wait_for_bridge "$tmp/out.jsonl" 10 || true   # Story 144: listener bound, not a fixed sleep

  # Populate both PRs concurrently. Capture each curl's PID so we wait
  # ONLY on the curls — `wait` with no arg would block on the
  # backgrounded bridge process too.
  curl -sS -X POST "http://127.0.0.1:$port/webhook" \
    -H "X-GitHub-Event: pull_request_review" \
    --data '{"repository":{"full_name":"test/repo"},"pull_request":{"number":101,"html_url":"https://example.com/pr/101"},"review":{"id":1000,"state":"COMMENTED","body":"a","html_url":"u1","user":{"login":"u1"}}}' >/dev/null &
  local cpid1=$!
  curl -sS -X POST "http://127.0.0.1:$port/webhook" \
    -H "X-GitHub-Event: pull_request_review" \
    --data '{"repository":{"full_name":"test/repo"},"pull_request":{"number":202,"html_url":"https://example.com/pr/202"},"review":{"id":2000,"state":"COMMENTED","body":"b","html_url":"u2","user":{"login":"u2"}}}' >/dev/null &
  local cpid2=$!
  wait "$cpid1" "$cpid2"
  sleep 0.5

  # Both cursors should exist with their respective populate IDs.
  local cur1="$tmp/test-repo/pr-101.cursor"
  local cur2="$tmp/test-repo/pr-202.cursor"
  if [ -f "$cur1" ] && [ -f "$cur2" ]; then
    PASS=$((PASS+1))
    assert_eq "case3: pr-101 cursor populated to 1000" "1000" "$(jq -r '.last_review_id // empty' "$cur1")"
    assert_eq "case3: pr-202 cursor populated to 2000" "2000" "$(jq -r '.last_review_id // empty' "$cur2")"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3: cursor file(s) missing — $(ls "$tmp/test-repo" 2>/dev/null)")
  fi

  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 4: forwarder keeps dying → bridge restarts up to 3 times then
# forces polling-only for the repo. We use a fake `gh webhook forward`
# bin that exits immediately, with a 1-second backoff knob so the cycle
# completes in ~3-4 seconds.
# ---------------------------------------------------------------------------
case_forwarder_restart() {
  local tmp; tmp="$(setup_tmp)"
  local port; port=$(pick_port)
  cat > "$tmp/bin/fake-forward" <<'EOF'
#!/usr/bin/env bash
# Exit immediately so the supervisor sees the child dying and retries.
exit 1
EOF
  chmod +x "$tmp/bin/fake-forward"
  cat > "$tmp/config.json" <<EOF
{"port": $port, "repos": ["test/repo"], "polling_interval_sec": 60, "mode": "webhook", "webhook_safety_net_interval_sec": 60, "webhook_forwarder_restart_backoff_sec": 1}
EOF

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/empty-pulls.json" \
    WOW_GH_EXTENSION_LIST_OUTPUT="github.com/cli/gh-webhook gh-webhook v0.0.1" \
    WOW_GH_WEBHOOK_FORWARD_BIN="$tmp/bin/fake-forward" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  # Story 144: wait for the SEQUENCE to complete (spawn + 3 deaths × backoff +
  # the exhaustion message) by polling for the terminal signal — a fixed `sleep 5`
  # was too short under load. Generous timeout; fall through to the assertions.
  wait_for_line "$tmp/out.jsonl" "exhausted retries" 20 || true
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  # Expect at least 3 "forwarder died" degraded statuses (one per restart).
  local died
  died=$(grep '"type":"bridge-status"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | select(.state == "degraded") | .reason' | grep -c "forwarder died" || echo 0)
  died=$(printf '%s' "$died" | tr -d '[:space:]')
  if [ "$died" -ge 3 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case4: expected ≥3 'forwarder died' messages, got $died")
  fi

  # Expect the final exhaustion message → polling-only for this repo.
  local exhausted
  exhausted=$(grep '"type":"bridge-status"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | select(.state == "degraded") | .reason' | grep -c "exhausted retries" || echo 0)
  exhausted=$(printf '%s' "$exhausted" | tr -d '[:space:]')
  if [ "$exhausted" -ge 1 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case4: expected 'exhausted retries' message, got $exhausted")
  fi

  rm -rf "$tmp"
}

case_extension_missing
case_webhook_emit
case_concurrent_different_prs
case_forwarder_restart

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
