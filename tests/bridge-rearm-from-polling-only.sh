#!/usr/bin/env bash
# Story 011 / Section A + B + C + E end-to-end regression test.
#
# Stages a stub `gh webhook forward` that fails the initial 3-retry
# budget AND the first re-arm spawn cycle's first attempt, then succeeds
# on the second re-arm spawn (forwarder stays up ≥ recovery threshold).
# Bridge stdout is parsed as JSONL.
#
# Asserts (in order):
#   - 3× `bridge-status: degraded` with `forwarder died` in the reason
#     (initial budget burn).
#   - 1× `bridge-status: degraded` with `polling-only` in the reason
#     (budget exhausted → polling-only transition).
#   - ≥ 1× `bridge-status: degraded` with `forwarder died` in the reason
#     (re-arm spawn cycle failures).
#   - 1× `bridge-status: armed` with `recovered:` in the reason
#     (re-arm cycle declared recovery).
#
# Compresses re-arm cadence + recovery threshold via env vars so the
# test fits in ~25s wall time.

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

assert_ge() {
  local name="$1"; local min="$2"; local actual="$3"
  if [ "$actual" -ge "$min" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected ≥$min, got $actual)")
  fi
}

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

case_rearm_recovers() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cp "$SHIM" "$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  printf '[]\n' > "$tmp/empty-pulls.json"

  # Counter-driven fake forwarder. Calls 1-4 fail immediately; call ≥ 5
  # stays alive until SIGTERM (matches real `gh webhook forward`
  # semantic — never exits on its own). The re-arm spawn cycle's
  # recovery-timeout check (RECOVERY_THRESHOLD=3s) declares recovery
  # via TimeoutExpired while the child is still running.
  cat > "$tmp/bin/fake-forward" <<'EOF'
#!/usr/bin/env bash
COUNTER="${WOW_FAKE_FORWARD_COUNTER:-/tmp/fake-forward-counter}"
n=$(cat "$COUNTER" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%d\n' "$n" > "$COUNTER"
if [ "$n" -le 4 ]; then
  echo "fake-forward call $n: synthetic failure" >&2
  exit 1
fi
exec sleep 86400
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
    WOW_FAKE_FORWARD_COUNTER="$tmp/forward-counter" \
    BRIDGE_REARM_INITIAL_INTERVAL_SEC=2 \
    BRIDGE_REARM_RECOVERY_THRESHOLD_SEC=3 \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!

  # Wait long enough for: 3 initial fails (with 1s backoff = ~3s) +
  # polling-only emit + 2s rearm wait + probe + spawn 4 fail + 1s
  # backoff + spawn 5 (3s recovery threshold). Total ~12-15s; pad to 22.
  sleep 22

  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  # Parse all bridge-status payloads from stdout.
  local statuses
  statuses=$(grep '"type":"bridge-status"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | "\(.state)|\(.reason)"')

  local n_died_initial
  n_died_initial=$(printf '%s\n' "$statuses" | grep -c "degraded|forwarder died for test/repo (initial restart" || true)
  n_died_initial=$(printf '%s' "$n_died_initial" | tr -d '[:space:]')
  assert_eq "case: 3 initial-budget death events" 3 "$n_died_initial"

  local n_polling_only
  n_polling_only=$(printf '%s\n' "$statuses" | grep -c "polling-only for this repo" || true)
  n_polling_only=$(printf '%s' "$n_polling_only" | tr -d '[:space:]')
  assert_eq "case: 1 polling-only transition" 1 "$n_polling_only"

  local n_died_rearm
  n_died_rearm=$(printf '%s\n' "$statuses" | grep -c "degraded|forwarder died for test/repo (re-arm restart" || true)
  n_died_rearm=$(printf '%s' "$n_died_rearm" | tr -d '[:space:]')
  assert_ge "case: ≥1 re-arm death event" 1 "$n_died_rearm"

  local n_recovered
  n_recovered=$(printf '%s\n' "$statuses" | grep -c "armed|recovered: test/repo" || true)
  n_recovered=$(printf '%s' "$n_recovered" | tr -d '[:space:]')
  assert_eq "case: 1 recovered emit" 1 "$n_recovered"

  rm -rf "$tmp"
}

case_rearm_recovers

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
