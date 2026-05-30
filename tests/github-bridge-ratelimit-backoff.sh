#!/usr/bin/env bash
# Story 167 — BEHAVIORAL: assert the OBSERVED cadence via bridge-status events
# (no monkeypatch). The list call is conditional (165), so the shim's sequenced
# status drives it: tick1 200, tick2 429 (+Retry-After), tick3+ 200 (recovery).
#   - (a) after the 429 tick -> a `throttled` bridge-status with interval_sec > floor.
#   - (b) after healthy ticks -> a bridge-status with interval_sec back at the floor.
# Cases a/b drive an EMPTY open list on purpose, so ONLY the list endpoint walks
# the 429 sequence — isolating the list-call reactive lever + recovery from the
# per-endpoint-counter sub-call cascade (each sub-endpoint has its own status
# counter, so a shared 200/429/200 sequence makes reviews/ci hit their own 429 a
# cycle late; with backoff-doubling that pushes a healthy recovery cycle past the
# kill window and case b can never observe the shrink-to-floor). The sub-call
# REACTIVE path is covered by case f (a real PR + a check-suites 429).
#   - (d) a 403 with remaining>0 + no Retry-After is an AUTH error -> DEGRADES, not throttle (BLOCKER-A).
#   - (e) low primary remaining via the rate_limit probe -> proactive widen (AC2).
#   - (f) reviews emit then a sub-call 429 -> cursor persisted, NO duplicate next cycle (R2-1).
#   - (g) a 403 WITH evidence (remaining:0) -> THROTTLES, not degrade (R2-2 positive).
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$REPO_ROOT/bridge/github/run.py"
SHIM="$REPO_ROOT/tests/fixtures/gh-shim.sh"
[ -f "$BRIDGE" ] && [ -f "$SHIM" ] || { echo "FATAL: missing bridge or shim" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }

PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$1 (expected '$2' got '$3')"); fi; }
ge1() { if [ "${2:-0}" -ge 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$1 (expected >=1 got '${2:-0}')"); fi; }
num() { printf '%s' "$1" | tr -d '[:space:]'; }
# bridge-status payloads with state==X and interval_sec OP floor -> count
istatus() { grep '"type":"bridge-status"' "$1" 2>/dev/null | while IFS= read -r l; do printf '%s' "$l" | jq -rc '.payload|fromjson|select(.state=="'"$2"'")|.interval_sec // empty'; done; }

t=$(mktemp -d); mkdir -p "$t/bin"; cp "$SHIM" "$t/bin/gh"; chmod +x "$t/bin/gh"
# floor = 1s so the test runs fast; throttled interval must exceed it.
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t/config.json"
# EMPTY open list -> only the list endpoint walks the status sequence (no PRs ->
# no sub-call fetches), so the throttle+recovery is driven purely by the list call.
printf '[]\n' > "$t/open.json"
# list-endpoint status sequence: 200, 429 (rate-limited), then 200 (recovery) x many.
{ echo 200; echo 429; for _ in $(seq 1 12); do echo 200; done; } > "$t/status.txt"
PATH="$t/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t/open.json" \
  WOW_GH_STATUS_LIST="$t/status.txt" WOW_GH_STATUS_COUNTER_DIR="$t" \
  WOW_GH_RETRY_AFTER="5" \
  WOW_GH_CALL_LOG="$t/calls.log" \
  python3 "$BRIDGE" --config "$t/config.json" > "$t/out.jsonl" 2>"$t/err.txt" &
# sleep 11: the recovery halves 5 -> 2 -> 1 over two healthy cycles after the
# throttle, so the shrink-to-floor (armed interval_sec==1) lands ~t8-9 — kill at
# 11 leaves margin.
pid=$!; sleep 11; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

# (a) a THROTTLED bridge-status with interval_sec > floor(1) was emitted after the 429.
THROTTLED_HI=$(istatus "$t/out.jsonl" throttled | awk '$1 > 1 {c++} END{print c+0}')
ge1 "a: throttled interval_sec > floor after 429" "$(num "$THROTTLED_HI")"
# (b) cadence recovered to the floor (an armed/recovery bridge-status interval_sec == 1).
REC_FLOOR=$(istatus "$t/out.jsonl" armed | awk '$1 == 1 {c++} END{print c+0}')
ge1 "b: cadence shrank back to floor after recovery" "$(num "$REC_FLOOR")"
# (c) no crash on the rate-limit path.
assert_eq "c: no python traceback" 0 "$(num "$(grep -c 'Traceback' "$t/err.txt" 2>/dev/null || true)")"
rm -rf "$t"

# ---- (d) BLOCKER-A negative: a 403 with remaining>0 + no Retry-After is an AUTH
#      error -> must DEGRADE (visible), NOT throttle silently. ----
t3=$(mktemp -d); mkdir -p "$t3/bin"; cp "$SHIM" "$t3/bin/gh"; chmod +x "$t3/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t3/config.json"
printf '[]\n' > "$t3/open.json"
{ for _ in $(seq 1 8); do echo 403; done; } > "$t3/status.txt"   # persistent auth-403 every cycle
PATH="$t3/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t3/open.json" \
  WOW_GH_STATUS_LIST="$t3/status.txt" WOW_GH_STATUS_COUNTER_DIR="$t3" \
  WOW_GH_RATELIMIT_REMAINING="4000" \
  python3 "$BRIDGE" --config "$t3/config.json" > "$t3/out.jsonl" 2>"$t3/err.txt" &
pid3=$!; sleep 6; kill -TERM "$pid3" 2>/dev/null; wait "$pid3" 2>/dev/null
ge1 "d: auth-403 (remaining>0, no Retry-After) DEGRADES" "$(num "$(grep '"type":"bridge-status"' "$t3/out.jsonl" 2>/dev/null | grep -c 'degraded' || true)")"
assert_eq "d: auth-403 did NOT throttle" 0 "$(num "$(istatus "$t3/out.jsonl" throttled | grep -c . || true)")"
rm -rf "$t3"

# ---- (e) PROACTIVE (AC2): low primary remaining (via _probe_network) widens the
#      cadence even with the list at 200. Probe every cycle (env override). ----
t4=$(mktemp -d); mkdir -p "$t4/bin"; cp "$SHIM" "$t4/bin/gh"; chmod +x "$t4/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t4/config.json"
printf '[]\n' > "$t4/open.json"
printf '{"resources":{"core":{"limit":5000,"remaining":3,"reset":0}}}\n' > "$t4/rl-low.json"
PATH="$t4/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t4/open.json" \
  WOW_GH_RATE_LIMIT_BODY="$t4/rl-low.json" \
  BRIDGE_RATELIMIT_PROBE_EVERY_N="1" \
  python3 "$BRIDGE" --config "$t4/config.json" > "$t4/out.jsonl" 2>"$t4/err.txt" &
pid4=$!; sleep 5; kill -TERM "$pid4" 2>/dev/null; wait "$pid4" 2>/dev/null
ge1 "e: low primary remaining widens cadence (throttled interval_sec > floor)" "$(num "$(istatus "$t4/out.jsonl" throttled | awk '$1 > 1 {c++} END{print c+0}')")"
assert_eq "e: no python traceback" 0 "$(num "$(grep -c 'Traceback' "$t4/err.txt" 2>/dev/null || true)")"
rm -rf "$t4"

# ---- (f) R2-1 (must be a REAL discriminator — RED without the finally): PRE-SEED
#      the cursor {state, last_review_id:7} so review id8 emits on CYCLE 1; the
#      discriminating re-fetch is then cycle2 (well inside the window), not a cycle
#      pushed past the kill by backoff-doubling. check-suites 429s every cycle. ----
t5=$(mktemp -d); mkdir -p "$t5/bin" "$t5/test-repo"; cp "$SHIM" "$t5/bin/gh"; chmod +x "$t5/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t5/config.json"
printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"s1"},"updated_at":"2026-05-30T10:00:00Z"}]\n' > "$t5/open.json"
printf '[{"id":8,"state":"COMMENTED","body":"b","html_url":"https://example.com/pr/1#r-8","user":{"login":"b"}}]\n' > "$t5/r8.json"
printf '{"check_suites":[]}\n' > "$t5/cs.json"
# Pre-seed: state present (not first-obs) + last_review_id:7 -> id8 EMITS on cycle1.
printf '{"state":"ready_for_review","last_review_id":7}\n' > "$t5/test-repo/pr-1.cursor"
PATH="$t5/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t5/open.json" WOW_GH_REVIEWS_FILE="$t5/r8.json" \
  WOW_GH_CHECK_SUITES_FILE="$t5/cs.json" WOW_GH_CHECK_SUITES_STATUS="429" WOW_GH_RETRY_AFTER="2" \
  python3 "$BRIDGE" --config "$t5/config.json" > "$t5/out.jsonl" 2>"$t5/err.txt" &
pid5=$!; sleep 7; kill -TERM "$pid5" 2>/dev/null; wait "$pid5" 2>/dev/null
# WITH the finally: cycle1 emits id8 + persists last_review_id=8 -> cycle2+ (id8<=8) NO emit -> count 1.
# WITHOUT it: every cycle reads the stale on-disk last_review_id=7 -> id8>7 -> RE-EMIT each cycle -> count >=2.
# (Impl MUST confirm this case is RED with the finally reverted — that's the R2-1 guard.)
assert_eq "f: R2-1 review id8 emitted exactly once (cursor persisted before throttle)" 1 "$(num "$(grep -c '"type":"pr-review"' "$t5/out.jsonl" 2>/dev/null || true)")"
ge1 "f: sub-call 429 threw a throttle" "$(num "$(istatus "$t5/out.jsonl" throttled | grep -c . || true)")"
assert_eq "f: no python traceback" 0 "$(num "$(grep -c 'Traceback' "$t5/err.txt" 2>/dev/null || true)")"
rm -rf "$t5"

# ---- (g) R2-2 positive: a 403 WITH evidence (x-ratelimit-remaining:0) THROTTLES. ----
t6=$(mktemp -d); mkdir -p "$t6/bin"; cp "$SHIM" "$t6/bin/gh"; chmod +x "$t6/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t6/config.json"
printf '[]\n' > "$t6/open.json"
{ echo 200; for _ in $(seq 1 8); do echo 403; done; } > "$t6/status.txt"
PATH="$t6/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t6/open.json" \
  WOW_GH_STATUS_LIST="$t6/status.txt" WOW_GH_STATUS_COUNTER_DIR="$t6" \
  WOW_GH_RATELIMIT_REMAINING="0" \
  python3 "$BRIDGE" --config "$t6/config.json" > "$t6/out.jsonl" 2>"$t6/err.txt" &
pid6=$!; sleep 6; kill -TERM "$pid6" 2>/dev/null; wait "$pid6" 2>/dev/null
ge1 "g: 403 + remaining:0 THROTTLES (positive evidence)" "$(num "$(istatus "$t6/out.jsonl" throttled | awk '$1 > 1 {c++} END{print c+0}')")"
assert_eq "g: 403+remaining:0 did NOT degrade" 0 "$(num "$(grep '"type":"bridge-status"' "$t6/out.jsonl" 2>/dev/null | grep -c 'degraded' || true)")"
rm -rf "$t6"

echo "github-bridge-ratelimit-backoff: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
