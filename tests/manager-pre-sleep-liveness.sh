#!/usr/bin/env bash
# Story 015 / Section D — pre-sleep liveness round + slow-cron fallback regression test.
#
# Synthetic-fixture bash test. Each case sets up a temp tree with a
# mocked bus (.message-bus.jsonl) and tracker (.agents/<id>.json),
# runs the inline liveness_decision helper (which mirrors M's prompt
# logic for the 10-quiet-tick threshold path: run_liveness_round +
# slow-cron-fallback + recovery), and asserts the next-action keyword
# plus tracker side-effects.
#
# Cases 5+6 also exercise the autonomy-gate's team_idle_check which
# consumes the shared cache (5-min freshness rule).
#
# The helpers ARE the spec for what M computes. If M's prompt diverges,
# this test fails — and the prompt edit should land in the same commit
# as the helper update.

set -u

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

# -----------------------------------------------------------------------------
# Inline helpers (spec for M's prompt logic)
# -----------------------------------------------------------------------------

# liveness_decision <fixture-dir>
#   Reads the fixture's bus + tracker. Simulates the 10-quiet-tick threshold
#   path: scan bus for fresh pongs (one per role), apply hello-grace if needed,
#   write tracker, then branch:
#     - all 3 roles pong AND tracker.cron_cadence == "fast" → "sleep_cron"
#     - all 3 roles pong AND tracker.cron_cadence == "slow" → "recovery"
#     - any role missing → "enter_slow_cron_fallback"
#   Prints the decision keyword. Side-effect: writes
#   last_liveness_round_ts + last_liveness_round_results into tracker.
liveness_decision() {
  local dir="$1"
  local bus="$dir/implementations/.message-bus.jsonl"
  local tracker="$dir/implementations/.agents/m.json"
  local cadence
  cadence=$(grep -oE '"cron_cadence"[[:space:]]*:[[:space:]]*"[^"]*"' "$tracker" | sed -E 's/.*"([^"]+)"$/\1/')

  # Scan bus for pongs from each role, in_reply_to a recent ping (we treat
  # any pong with role-matching `from` as valid for the synthetic test).
  local sd_ok=false pp_ok=false t_ok=false
  if grep -qE '"type":[[:space:]]*"pong"' "$bus" && grep -qE '"from":[[:space:]]*"senior-developer-' "$bus"; then sd_ok=true; fi
  if grep -qE '"type":[[:space:]]*"pong"' "$bus" && grep -qE '"from":[[:space:]]*"pair-programmer-' "$bus"; then pp_ok=true; fi
  if grep -qE '"type":[[:space:]]*"pong"' "$bus" && grep -qE '"from":[[:space:]]*"tester-' "$bus"; then t_ok=true; fi

  # Hello-grace pass: for any role still missing, scan bus for a recent
  # `hello` from that role within the last ~30 s. In synthetic time we
  # treat any `hello` line as recent if it's the LAST line for that role.
  if [ "$sd_ok" = false ] && grep -qE '"type":[[:space:]]*"hello".*"from":[[:space:]]*"senior-developer-' "$bus"; then sd_ok=true; fi
  if [ "$pp_ok" = false ] && grep -qE '"type":[[:space:]]*"hello".*"from":[[:space:]]*"pair-programmer-' "$bus"; then pp_ok=true; fi
  if [ "$t_ok" = false ] && grep -qE '"type":[[:space:]]*"hello".*"from":[[:space:]]*"tester-' "$bus"; then t_ok=true; fi

  # Write tracker side-effects (last_liveness_round_ts + _results).
  local now_iso="2026-05-01T16:00:00Z"
  local results
  results="{\"sd\":$sd_ok,\"pp\":$pp_ok,\"t\":$t_ok}"
  cat > "$tracker.new" <<JSON
{"cron_cadence":"$cadence","last_liveness_round_ts":"$now_iso","last_liveness_round_results":$results}
JSON
  mv "$tracker.new" "$tracker"

  # Branch on result.
  if [ "$sd_ok" = true ] && [ "$pp_ok" = true ] && [ "$t_ok" = true ]; then
    if [ "$cadence" = "slow" ]; then
      # Recovery: fast cron, cadence flips back.
      cat > "$tracker.new" <<JSON
{"cron_cadence":"fast","last_liveness_round_ts":"$now_iso","last_liveness_round_results":$results}
JSON
      mv "$tracker.new" "$tracker"
      echo "recovery"
    else
      echo "sleep_cron"
    fi
  else
    # Slow-cron fallback: cadence flips to slow.
    cat > "$tracker.new" <<JSON
{"cron_cadence":"slow","last_liveness_round_ts":"$now_iso","last_liveness_round_results":$results}
JSON
    mv "$tracker.new" "$tracker"
    echo "enter_slow_cron_fallback"
  fi
}

# team_idle_check <fixture-dir> <now-iso>
#   Reads tracker. If last_liveness_round_ts is ≤ 5 min old AND every role
#   in last_liveness_round_results is true, prints "cache_hit_idle".
#   Otherwise runs a fresh liveness_decision (which writes the cache) and
#   prints "fresh_round_ran:<decision>".
team_idle_check() {
  local dir="$1"; local now_iso="$2"
  local tracker="$dir/implementations/.agents/m.json"
  local last_ts
  last_ts=$(grep -oE '"last_liveness_round_ts"[[:space:]]*:[[:space:]]*"[^"]*"' "$tracker" | sed -E 's/.*"([^"]+)"$/\1/')

  # If null/empty → fresh round.
  if [ -z "$last_ts" ] || [ "$last_ts" = "null" ]; then
    local decision; decision=$(liveness_decision "$dir")
    echo "fresh_round_ran:$decision"
    return
  fi

  # Compute age in seconds (date -j for macOS, date -d for linux).
  local now_epoch last_epoch age_sec
  if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$now_iso" '+%s' >/dev/null 2>&1; then
    now_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$now_iso" '+%s')
    last_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_ts" '+%s')
  else
    now_epoch=$(date -d "$now_iso" '+%s')
    last_epoch=$(date -d "$last_ts" '+%s')
  fi
  age_sec=$((now_epoch - last_epoch))

  # Check freshness (≤ 300 s) AND all roles true.
  local all_true="true"
  if grep -qE '"sd"[[:space:]]*:[[:space:]]*false' "$tracker"; then all_true="false"; fi
  if grep -qE '"pp"[[:space:]]*:[[:space:]]*false' "$tracker"; then all_true="false"; fi
  if grep -qE '"t"[[:space:]]*:[[:space:]]*false' "$tracker"; then all_true="false"; fi

  if [ "$age_sec" -le 300 ] && [ "$all_true" = "true" ]; then
    echo "cache_hit_idle"
  else
    local decision; decision=$(liveness_decision "$dir")
    echo "fresh_round_ran:$decision"
  fi
}

# -----------------------------------------------------------------------------
# Fixture builder
# -----------------------------------------------------------------------------

# new_fixture <init-cadence> -> prints the dir
new_fixture() {
  local cadence="$1"
  local dir; dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'liveness')
  mkdir -p "$dir/implementations/.agents"
  : > "$dir/implementations/.message-bus.jsonl"
  cat > "$dir/implementations/.agents/m.json" <<JSON
{"cron_cadence":"$cadence","last_liveness_round_ts":null,"last_liveness_round_results":null}
JSON
  echo "$dir"
}

# write_pong <fixture-dir> <role>
write_pong() {
  local dir="$1"; local role="$2"
  local from
  case "$role" in
    sd) from="senior-developer-20260501T120000-aaaaaa" ;;
    pp) from="pair-programmer-20260501T120000-bbbbbb" ;;
    t)  from="tester-20260501T120000-cccccc" ;;
  esac
  printf '{"ts":"2026-05-01T15:59:30Z","from":"%s","to":"manager-*","type":"pong","in_reply_to":{"ts":"2026-05-01T15:59:29Z","from":"manager-test"}}\n' "$from" >> "$dir/implementations/.message-bus.jsonl"
}

# write_hello <fixture-dir> <role>
write_hello() {
  local dir="$1"; local role="$2"
  local from
  case "$role" in
    sd) from="senior-developer-20260501T155945-aaaaaa" ;;
    pp) from="pair-programmer-20260501T155945-bbbbbb" ;;
    t)  from="tester-20260501T155945-cccccc" ;;
  esac
  printf '{"ts":"2026-05-01T15:59:45Z","from":"%s","to":"*","type":"hello","payload":"%s"}\n' "$from" "$role" >> "$dir/implementations/.message-bus.jsonl"
}

# set_tracker_cache <fixture-dir> <iso-ts> <sd> <pp> <t>
set_tracker_cache() {
  local dir="$1"; local ts="$2"; local sd="$3"; local pp="$4"; local t="$5"
  local tracker="$dir/implementations/.agents/m.json"
  local cadence
  cadence=$(grep -oE '"cron_cadence"[[:space:]]*:[[:space:]]*"[^"]*"' "$tracker" | sed -E 's/.*"([^"]+)"$/\1/')
  cat > "$tracker" <<JSON
{"cron_cadence":"$cadence","last_liveness_round_ts":"$ts","last_liveness_round_results":{"sd":$sd,"pp":$pp,"t":$t}}
JSON
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: all-alive (in fast) → sleep_cron
DIR=$(new_fixture "fast")
write_pong "$DIR" sd
write_pong "$DIR" pp
write_pong "$DIR" t
RESULT=$(liveness_decision "$DIR")
assert_eq "case-1-all-alive-sleep_cron" "sleep_cron" "$RESULT"
# Tracker side-effects: cron_cadence stays fast; results all true.
assert_eq "case-1-cron_cadence-stays-fast" "fast" "$(grep -oE '"cron_cadence"[[:space:]]*:[[:space:]]*"[^"]*"' "$DIR/implementations/.agents/m.json" | sed -E 's/.*"([^"]+)"$/\1/')"
assert_eq "case-1-sd-true" "true" "$(grep -oE '"sd"[[:space:]]*:[[:space:]]*(true|false)' "$DIR/implementations/.agents/m.json" | sed -E 's/.*:[[:space:]]*//')"
rm -rf "$DIR"

# Case 2: one missing (in fast) → enter_slow_cron_fallback
DIR=$(new_fixture "fast")
write_pong "$DIR" sd
write_pong "$DIR" pp
# T silent (no pong, no hello)
RESULT=$(liveness_decision "$DIR")
assert_eq "case-2-one-missing-fallback" "enter_slow_cron_fallback" "$RESULT"
assert_eq "case-2-cron_cadence-slow" "slow" "$(grep -oE '"cron_cadence"[[:space:]]*:[[:space:]]*"[^"]*"' "$DIR/implementations/.agents/m.json" | sed -E 's/.*"([^"]+)"$/\1/')"
assert_eq "case-2-t-false" "false" "$(grep -oE '"t"[[:space:]]*:[[:space:]]*(true|false)' "$DIR/implementations/.agents/m.json" | sed -E 's/.*:[[:space:]]*//')"
rm -rf "$DIR"

# Case 3: recovery (in slow, all peers back) → recovery
DIR=$(new_fixture "slow")
write_pong "$DIR" sd
write_pong "$DIR" pp
write_pong "$DIR" t
RESULT=$(liveness_decision "$DIR")
assert_eq "case-3-recovery" "recovery" "$RESULT"
assert_eq "case-3-cron_cadence-flips-fast" "fast" "$(grep -oE '"cron_cadence"[[:space:]]*:[[:space:]]*"[^"]*"' "$DIR/implementations/.agents/m.json" | sed -E 's/.*"([^"]+)"$/\1/')"
rm -rf "$DIR"

# Case 4: hello-grace — peer missing pong but has recent hello → counts as alive
DIR=$(new_fixture "fast")
write_pong "$DIR" sd
write_pong "$DIR" pp
# T missing pong but has fresh hello (compaction recovery)
write_hello "$DIR" t
RESULT=$(liveness_decision "$DIR")
assert_eq "case-4-hello-grace-sleep" "sleep_cron" "$RESULT"
assert_eq "case-4-t-true-after-grace" "true" "$(grep -oE '"t"[[:space:]]*:[[:space:]]*(true|false)' "$DIR/implementations/.agents/m.json" | sed -E 's/.*:[[:space:]]*//')"
rm -rf "$DIR"

# Case 5: autonomy-gate cache reuse — cache fresh + all true → cache_hit_idle (no fresh ping)
DIR=$(new_fixture "fast")
# Pre-seed cache with a fresh ts (just 60s old) and all-true results.
set_tracker_cache "$DIR" "2026-05-01T15:59:00Z" "true" "true" "true"
# Bus is EMPTY — no pongs available. Cache hit must succeed without a fresh ping.
RESULT=$(team_idle_check "$DIR" "2026-05-01T16:00:00Z")
assert_eq "case-5-cache-hit-idle" "cache_hit_idle" "$RESULT"
# Bus still empty — confirms no fresh ping was emitted.
BUS_LINES=$(wc -l < "$DIR/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-5-no-bus-writes" "0" "$BUS_LINES"
rm -rf "$DIR"

# Case 6: autonomy-gate cache stale — cache > 5 min old → fresh round runs
DIR=$(new_fixture "fast")
# Pre-seed cache with a stale ts (10 min old).
set_tracker_cache "$DIR" "2026-05-01T15:50:00Z" "true" "true" "true"
# Bus has fresh pongs to satisfy the new round.
write_pong "$DIR" sd
write_pong "$DIR" pp
write_pong "$DIR" t
RESULT=$(team_idle_check "$DIR" "2026-05-01T16:00:00Z")
assert_eq "case-6-stale-runs-fresh" "fresh_round_ran:sleep_cron" "$RESULT"
# Tracker now reflects the fresh round.
assert_eq "case-6-cache-updated-ts" "2026-05-01T16:00:00Z" "$(grep -oE '"last_liveness_round_ts"[[:space:]]*:[[:space:]]*"[^"]*"' "$DIR/implementations/.agents/m.json" | sed -E 's/.*"([^"]+)"$/\1/')"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Case (g) — Story 108: M's pre-sleep liveness section in manager.md uses the
# post-hoc `sleep 90 && jq` scan pattern, NOT the racy inline polling loop.
# Anti-revert pins three shapes in the Liveness paragraph + the canonical-bug
# anti-pin from PP round-1.
# -----------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MGR="$ROOT/commands/manager.md"
if [ ! -f "$MGR" ]; then
  echo "FATAL: manager.md not found at $MGR" >&2
  exit 2
fi

if grep -q "sleep 90" "$MGR"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("g-sleep-90-present (manager.md missing the sleep 90 post-hoc scan shape)")
fi

if grep -qF 'select(.type == "pong" and .in_reply_to.ts >= $cutoff)' "$MGR"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("g-jq-pong-cutoff-pattern (manager.md missing the correct post-hoc jq pong filter — must be .in_reply_to.ts; bus_emit MCP server wraps in_reply_to into {ts, from} object so .in_reply_to alone is dict + dict >= \$cutoff is always-true — FINDING-32)")
fi

# Negative anti-revert (FINDING-32 amendment): the flat-compare form
# `.in_reply_to >= $cutoff` (no .ts) is the always-true bug. mcp-server
# wraps in_reply_to into {"ts": ...} on emit (server.py:335), so
# `.in_reply_to` is a dict and `dict >= "<string>"` returns true in jq
# (objects sort after strings). PP's round-2 review misdirected to the
# flat-compare form; M's FINDING-32 caught the always-true result.
if grep -qF '.in_reply_to >= $cutoff' "$MGR"; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("g-no-flat-in_reply_to-compare (manager.md contains '.in_reply_to >= \$cutoff' without .ts — FINDING-32 always-true bug shape)")
else
  PASS=$((PASS+1))
fi

# Anti-revert: the racy inline polling shape ('sleep 3' as the per-tick
# cadence in a Pre-sleep liveness loop) must NOT appear in manager.md.
if grep -q 'sleep 3' "$MGR"; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("g-no-sleep-3-polling (manager.md contains 'sleep 3' — Story 108 racy-polling-loop revert)")
else
  PASS=$((PASS+1))
fi

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "manager-pre-sleep-liveness: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
