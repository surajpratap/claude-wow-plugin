#!/usr/bin/env bash
# Story 011 / Section D regression test.
#
# Stages a stub `gh webhook forward` that emits a known stderr line
# ("websocket: close 1006") and exits 1. Verifies:
#   (i) The line lands in ${ROOT}/implementations/.github/forwarder.<slug>.log
#   (ii) The next bridge-status: degraded JSONL on bridge stdout has a
#        last_stderr field whose payload contains "close 1006".

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$REPO_ROOT/bridge/github/run.py"
SHIM="$REPO_ROOT/tests/fixtures/gh-shim.sh"

if [ ! -f "$BRIDGE" ] || [ ! -f "$SHIM" ]; then
  echo "FATAL: missing bridge or shim" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: jq + python3 required" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILED_CASES=()

assert_contains() {
  local name="$1"; local needle="$2"; local haystack="$3"
  if printf '%s' "$haystack" | grep -q -F "$needle"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected to contain '$needle', got '$haystack')")
  fi
}

pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

case_stderr_captured() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cp "$SHIM" "$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  printf '[]\n' > "$tmp/empty-pulls.json"

  cat > "$tmp/bin/fake-forward" <<'EOF'
#!/usr/bin/env bash
echo "websocket: close 1006 abnormal closure" >&2
exit 1
EOF
  chmod +x "$tmp/bin/fake-forward"

  local port; port=$(pick_port)
  cat > "$tmp/config.json" <<EOF
{"port": $port, "repos": ["test/repo"], "polling_interval_sec": 60, "mode": "webhook", "webhook_safety_net_interval_sec": 60, "webhook_forwarder_restart_backoff_sec": 1}
EOF

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/empty-pulls.json" \
    WOW_GH_EXTENSION_LIST_OUTPUT="github.com/cli/gh-webhook gh-webhook v0.0.1" \
    WOW_GH_WEBHOOK_FORWARD_BIN="$tmp/bin/fake-forward" \
    BRIDGE_REARM_RECOVERY_THRESHOLD_SEC=2 \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!

  # Initial 3 spawns × ~0.1s + 2× 1s backoffs = ~3s. Pad to 6s.
  sleep 6

  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local log_path="$tmp/forwarder.test-repo.log"
  if [ -f "$log_path" ]; then
    local log_content; log_content=$(cat "$log_path")
    assert_contains "log file contains 'close 1006'" "close 1006" "$log_content"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("forwarder log file missing at $log_path")
  fi

  # Find the first bridge-status: degraded with last_stderr field.
  local first_with_stderr
  first_with_stderr=$(grep '"type":"bridge-status"' "$tmp/out.jsonl" | jq -rc 'select(.payload | fromjson | has("last_stderr")) | .payload | fromjson | .last_stderr' | head -1)
  assert_contains "first degraded payload's last_stderr contains 'close 1006'" "close 1006" "$first_with_stderr"

  rm -rf "$tmp"
}

case_stderr_captured

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
