#!/usr/bin/env bash
# Story 168 — BEHAVIORAL: a sub-call (reviews) failure surfaces as
# bridge-status:degraded via the SAME failure_counts/DEGRADATION_THRESHOLD
# machinery the list call uses; an EMPTY result does NOT. Threshold-respecting
# (>=3 consecutive failing cycles -> EXACTLY ONE degraded). No monkeypatch —
# drives the real subprocess; WOW_GH_FAIL_PATH_GLOB / WOW_GH_FAIL_GLOB_FILE make
# the sub-call raise a plain RuntimeError (bare path, not _RateLimited).
#
# Cases (a)/(c) POLL for the expected bridge-status event (up to a timeout)
# rather than sleeping a fixed wall-clock window — under full-suite load the
# bridge's poll cycles slow down (subprocess-spawn latency), so a fixed sleep
# can yield too few cycles and the degrade/recover misses its window (a flake).
# Polling waits for the actual condition, so it's robust to load AND fast when
# idle. Cases (b)/(d) assert ABSENCE in the safe direction (fewer cycles still
# holds) so they keep a bounded fixed window.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$REPO_ROOT/bridge/github/run.py"
SHIM="$REPO_ROOT/tests/fixtures/gh-shim.sh"
[ -f "$BRIDGE" ] && [ -f "$SHIM" ] || { echo "FATAL: missing bridge or shim" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }

PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$1 (expected '$2' got '$3')"); fi; }
num() { printf '%s' "$1" | tr -d '[:space:]'; }
# count bridge-status whose state==$2 and reason matches $3 (regex; '.' = any)
status_named() { grep '"type":"bridge-status"' "$1" 2>/dev/null | while IFS= read -r l; do printf '%s' "$l" | jq -rc 'select((.payload|fromjson|.state)=="'"$2"'")|.payload|fromjson|.reason'; done | grep -c "$3"; }
deg_named() { status_named "$1" degraded "$2"; }
# poll until `grep -c "$2" "$1"` >= $3, or $4 seconds elapse (0.5s cadence).
wait_for() {
  local i=0 max=$(( $4 * 2 )) cnt
  while [ "$i" -lt "$max" ]; do
    cnt=$(grep -c "$2" "$1" 2>/dev/null || true)
    if [ "${cnt:-0}" -ge "$3" ]; then return 0; fi
    sleep 0.5; i=$((i+1))
  done
  return 1
}

# ---- (a) reviews fails every cycle -> EXACTLY ONE degraded naming "reviews"
#      (only after >= DEGRADATION_THRESHOLD(3) cycles; one-shot guard holds). ----
t=$(mktemp -d); mkdir -p "$t/bin"; cp "$SHIM" "$t/bin/gh"; chmod +x "$t/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t/config.json"
printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"s1"},"updated_at":"2026-05-30T10:00:00Z"}]\n' > "$t/open.json"
PATH="$t/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t/open.json" \
  WOW_GH_FAIL_PATH_GLOB='*/reviews' \
  python3 "$BRIDGE" --config "$t/config.json" > "$t/out.jsonl" 2>"$t/err.txt" &
pid=$!
wait_for "$t/out.jsonl" 'degraded' 1 40 || true   # wait for the degrade (>=3 cycles); generous ceiling (returns early)
sleep 2                                            # +2 cycles to expose any (wrongly) repeated degrade
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
assert_eq "a: exactly one degraded naming reviews" 1 "$(num "$(deg_named "$t/out.jsonl" 'reviews')")"
assert_eq "a: degraded emitted exactly once total" 1 "$(num "$(grep '"type":"bridge-status"' "$t/out.jsonl" 2>/dev/null | grep -c 'degraded')")"
assert_eq "a: no python traceback" 0 "$(num "$(grep -c 'Traceback' "$t/err.txt" 2>/dev/null || true)")"
rm -rf "$t"

# ---- (b) reviews returns [] (legitimately empty) every cycle -> 0 degraded
#      (an empty result must NOT increment the failure count). Fixed window:
#      asserts ABSENCE — fewer cycles under load still holds. ----
t2=$(mktemp -d); mkdir -p "$t2/bin"; cp "$SHIM" "$t2/bin/gh"; chmod +x "$t2/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t2/config.json"
printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"s1"},"updated_at":"2026-05-30T10:00:00Z"}]\n' > "$t2/open.json"
printf '[]\n' > "$t2/reviews.json"
PATH="$t2/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t2/open.json" WOW_GH_REVIEWS_FILE="$t2/reviews.json" \
  python3 "$BRIDGE" --config "$t2/config.json" > "$t2/out.jsonl" 2>"$t2/err.txt" &
pid2=$!; sleep 5; kill -TERM "$pid2" 2>/dev/null; wait "$pid2" 2>/dev/null
assert_eq "b: empty reviews -> 0 degraded" 0 "$(num "$(grep '"type":"bridge-status"' "$t2/out.jsonl" 2>/dev/null | grep -c 'degraded')")"
assert_eq "b: no python traceback" 0 "$(num "$(grep -c 'Traceback' "$t2/err.txt" 2>/dev/null || true)")"
rm -rf "$t2"

# ---- (c) R1: the RELOCATED recovered-emit + degraded[repo] reset is load-bearing
#      (a stuck `degraded` alert never clears if it regresses) and otherwise UNTESTED.
#      Fail reviews >=3 cycles (degrade), then reviews succeeds (-> exactly one
#      `recovered: <repo>` armed + degraded[repo] reset), then fail again >=3 cycles
#      (re-degrade -> PROVES degraded[repo] was reset; else the one-shot guard
#      suppresses it). Uses the file-toggle shim knob so reviews flips fail->ok->fail
#      IN ONE process; POLLS each phase (load-robust). WITHOUT the relocation:
#      degraded[repo] stays True after phase 1 -> no recovered emit AND phase-3
#      re-degrade suppressed -> degraded count 1 (not 2) + recovered count 0.
#      (Impl MUST confirm case c is RED with the recovered-emit/reset reverted.)
t3=$(mktemp -d); mkdir -p "$t3/bin"; cp "$SHIM" "$t3/bin/gh"; chmod +x "$t3/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t3/config.json"
printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"s1"},"updated_at":"2026-05-30T10:00:00Z"}]\n' > "$t3/open.json"
printf '%s' '*/reviews' > "$t3/glob"          # phase 1: reviews fails
PATH="$t3/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t3/open.json" \
  WOW_GH_FAIL_GLOB_FILE="$t3/glob" \
  python3 "$BRIDGE" --config "$t3/config.json" > "$t3/out.jsonl" 2>"$t3/err.txt" &
pid3=$!
# FINDING-46: generous wait_for ceilings — case c is a ~7-cycle 3-phase sequence
# (degrade[3] -> recover[1] -> re-degrade[3]); under heavy load per-cycle latency
# rises, so tight ceilings time out (false-FAIL). wait_for returns the INSTANT the
# condition is met, so a large ceiling is free on a fast run + only helps under load.
wait_for "$t3/out.jsonl" 'degraded' 1 40 || true            # phase 1 -> degrade (>=3 cycles)
: > "$t3/glob"                                               # phase 2: reviews recovers
wait_for "$t3/out.jsonl" 'recovered: test/repo' 1 30 || true # phase 2 -> exactly one recovered (1 clean cycle)
printf '%s' '*/reviews' > "$t3/glob"                         # phase 3: reviews fails again
wait_for "$t3/out.jsonl" 'degraded' 2 60 || true             # phase 3 -> re-degrade (>=3 more cycles)
sleep 1
kill -TERM "$pid3" 2>/dev/null; wait "$pid3" 2>/dev/null
assert_eq "c: degraded fired TWICE (proves degraded[repo] reset on recovery)" 2 "$(num "$(deg_named "$t3/out.jsonl" 'reviews')")"
assert_eq "c: exactly one repo-recovered emit" 1 "$(num "$(status_named "$t3/out.jsonl" armed 'recovered: test/repo')")"
assert_eq "c: no python traceback" 0 "$(num "$(grep -c 'Traceback' "$t3/err.txt" 2>/dev/null || true)")"
rm -rf "$t3"

# ---- (d) R2: a MULTI-endpoint failure (reviews + BOTH comment endpoints) in the
#      same cycle must STILL need >= DEGRADATION_THRESHOLD *cycles* — the code
#      increments +1 per FAILING CYCLE, NOT +len(failures). One fail-glob `*/1/*`
#      matches all THREE PR-#1 sub-call endpoints (/pulls/1/reviews,
#      /issues/1/comments, /pulls/1/comments) but NOT the list (/pulls?state=open —
#      no `/1/`) nor check-suites (/commits/abc/check-suites — sha has no `/1/`).
#      (A `|`-alternation in WOW_GH_FAIL_PATH_GLOB would be INERT — bash treats a `|`
#      from a ${var} expansion as a literal glob char, not case alternation; so a
#      single no-`|` glob is required.) interval=2 so cycles land ~t0/t2/t4; kill at
#      3s (cycle 3 @ ~t4 not reached) -> correct +1/cycle: 0 degraded after 2 cycles.
#      A `+= len(failures)` regression hits 3 in cycle 1 -> degrade at ~t0 -> caught.
#      Fixed window asserts ABSENCE in the safe direction (load -> fewer cycles ->
#      still 0). (Impl MUST confirm case d is RED under a +=len impl.)
t4=$(mktemp -d); mkdir -p "$t4/bin"; cp "$SHIM" "$t4/bin/gh"; chmod +x "$t4/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 2}\n' > "$t4/config.json"
printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"abc"},"updated_at":"2026-05-30T10:00:00Z"}]\n' > "$t4/open.json"
PATH="$t4/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t4/open.json" \
  WOW_GH_FAIL_PATH_GLOB='*/1/*' \
  python3 "$BRIDGE" --config "$t4/config.json" > "$t4/out.jsonl" 2>"$t4/err.txt" &
pid4=$!; sleep 3; kill -TERM "$pid4" 2>/dev/null; wait "$pid4" 2>/dev/null
assert_eq "d: multi-endpoint failure still needs >=3 cycles (0 degraded at ~2 cycles)" 0 "$(num "$(grep '"type":"bridge-status"' "$t4/out.jsonl" 2>/dev/null | grep -c 'degraded')")"
assert_eq "d: no python traceback" 0 "$(num "$(grep -c 'Traceback' "$t4/err.txt" 2>/dev/null || true)")"
rm -rf "$t4"

echo "github-bridge-subcall-degraded: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
