#!/usr/bin/env bash
# Verify the trim-threshold contract that commands/manager.md gives M:
#
#   - Below threshold (default 2000): the trim block is a no-op. Bus content
#     is unchanged after the block runs.
#   - At/above threshold: the trim block runs and rewrites the bus to keep
#     only lines newer than the 24h cutoff.
#
# This test reproduces the trim block as a bash function (the contract) and
# exercises it against synthetic buses. It does NOT parse manager.md byte-
# for-byte — that's PP's review concern. It tests that the contract
# behaves correctly against the inputs M would feed it in production.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required" >&2
  exit 2
fi

# Cross-platform 24h-ago ISO-8601 in UTC.
cutoff_24h_ago() {
  date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ
}

# The contract under test — verbatim shape from manager.md Phase 1 step 5
# / Phase 5 step 1, parameterized to take a bus path + a threshold-file path.
trim_block() {
  local bus="$1"
  local threshold_file="$2"
  local threshold=2000
  [ -f "$threshold_file" ] && threshold=$(cat "$threshold_file" | tr -d ' \n')
  local lines
  lines=$(wc -l < "$bus" 2>/dev/null | tr -d ' '); lines=${lines:-0}
  if [ "$lines" -ge "$threshold" ]; then
    local cutoff
    cutoff=$(cutoff_24h_ago)
    jq -c --arg cutoff "$cutoff" 'select(.ts >= $cutoff)' "$bus" > "$bus.tmp" \
      && mv "$bus.tmp" "$bus"
  fi
}

# Generate N bus lines: $aged of them with ts older than 24h, $fresh fresh.
gen_bus() {
  local bus="$1"
  local aged="$2"
  local fresh="$3"
  : > "$bus"
  local aged_ts; aged_ts=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
  local fresh_ts; fresh_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local i
  for ((i=1; i<=aged; i++)); do
    printf '{"ts":"%s","from":"x","to":"*","type":"aged-%d"}\n' "$aged_ts" "$i" >> "$bus"
  done
  for ((i=1; i<=fresh; i++)); do
    printf '{"ts":"%s","from":"x","to":"*","type":"fresh-%d"}\n' "$fresh_ts" "$i" >> "$bus"
  done
}

assert_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected $expected, got $actual)")
  fi
}

# ---------------------------------------------------------------------------
# Case 1: 1500 lines (below 2000-line default) — no-op.
# ---------------------------------------------------------------------------
case_below() {
  local tmp; tmp="$(mktemp -d)"
  local bus="$tmp/bus.jsonl"
  local threshold_file="$tmp/threshold-not-present"   # missing → default 2000
  gen_bus "$bus" 500 1000
  local before_total; before_total=$(wc -l < "$bus" | tr -d ' ')
  local before_aged;  before_aged=$(grep -c '"type":"aged-' "$bus")

  trim_block "$bus" "$threshold_file"

  local after_total;  after_total=$(wc -l < "$bus" | tr -d ' ')
  local after_aged;   after_aged=$(grep -c '"type":"aged-' "$bus")

  assert_eq "below-threshold (line count unchanged)" "$before_total" "$after_total"
  assert_eq "below-threshold (aged lines retained)"  "$before_aged"  "$after_aged"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 2: 2500 lines (1500 aged + 1000 fresh) — trim runs, drops aged.
# ---------------------------------------------------------------------------
case_above() {
  local tmp; tmp="$(mktemp -d)"
  local bus="$tmp/bus.jsonl"
  local threshold_file="$tmp/threshold-not-present"   # default 2000
  gen_bus "$bus" 1500 1000

  trim_block "$bus" "$threshold_file"

  local after_total;  after_total=$(wc -l < "$bus" | tr -d ' ')
  local after_aged;   after_aged=$(grep -c '"type":"aged-' "$bus" || true)
  local after_fresh;  after_fresh=$(grep -c '"type":"fresh-' "$bus" || true)

  assert_eq "above-threshold (line count = fresh count)" 1000 "$after_total"
  assert_eq "above-threshold (no aged lines remain)"     0    "$after_aged"
  assert_eq "above-threshold (all fresh lines remain)"   1000 "$after_fresh"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 3: custom threshold file at 100 — 150 fresh lines should now be
# above-threshold and trigger trim, even though there's nothing aged to drop
# (idempotent, content unchanged).
# ---------------------------------------------------------------------------
case_custom_threshold() {
  local tmp; tmp="$(mktemp -d)"
  local bus="$tmp/bus.jsonl"
  local threshold_file="$tmp/.bus-trim-threshold"
  printf '%d\n' 100 > "$threshold_file"
  gen_bus "$bus" 0 150
  local before_total; before_total=$(wc -l < "$bus" | tr -d ' ')

  trim_block "$bus" "$threshold_file"

  local after_total; after_total=$(wc -l < "$bus" | tr -d ' ')

  # Trim ran (file was rewritten), but nothing aged → all 150 fresh remain.
  assert_eq "custom-threshold (all fresh retained)" "$before_total" "$after_total"

  rm -rf "$tmp"
}

case_below
case_above
case_custom_threshold

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
