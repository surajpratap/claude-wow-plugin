#!/usr/bin/env bash
# Story 165 — BEHAVIORAL, and it must EXERCISE the real 304 path: the gh-shim now
# exits NONZERO on a >299 status (incl 304), like real `gh`. No _gh_api monkeypatch.
#   - LIST + reviews are status-sequenced 200 -> 304 (per-endpoint counter via
#     WOW_GH_STATUS_COUNTER_DIR): each endpoint's 1st call = 200 + ETag E1 (cached),
#     2nd+ = 304 (rc!=0) which the bridge MUST serve from cache.
#   - DECISIVE BLOCKER-1 distinguisher: the LIST call is conditional. If _gh_api
#     raised on the 304's nonzero rc, the list exception is caught by the poll loop
#     and after DEGRADATION_THRESHOLD emits `bridge-status: degraded`. A correct
#     cached-serve emits NONE -> we assert 0 degraded events. (A swallowed-exception
#     or [] bug can't pass this; it targets the raise-on-rc class.)
#   - SEPARATE malformed-header run: the parse-ambiguity bare-GET fallback actually
#     RETURNS the body -> the reviews cursor is populated (observable), not just
#     "a path was logged".
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
INM=$(printf 'IF-NONE-MATCH\t/repos/test/repo/pulls/1/reviews')

# ---- Main run: list + reviews 200 -> 304; the 304s must be served from cache ----
t=$(mktemp -d); mkdir -p "$t/bin"; cp "$SHIM" "$t/bin/gh"; chmod +x "$t/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t/config.json"
printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"s1"}}]\n' > "$t/open.json"
printf '[{"id":100,"state":"COMMENTED","body":"hi","html_url":"https://example.com/pr/1#r-100","user":{"login":"alice"}}]\n' > "$t/reviews.json"
# per-endpoint: 1st call 200, all later calls 304 (padded so it never runs out).
{ echo 200; i=0; while [ "$i" -lt 12 ]; do echo 304; i=$((i+1)); done; } > "$t/status.txt"
PATH="$t/bin:$PATH" \
  WOW_GH_RESPONSE_FILE="$t/open.json" WOW_GH_REVIEWS_FILE="$t/reviews.json" \
  WOW_GH_STATUS_LIST="$t/status.txt" WOW_GH_STATUS_COUNTER_DIR="$t" WOW_GH_ETAG='"E1"' \
  WOW_GH_CALL_LOG="$t/calls.log" \
  python3 "$BRIDGE" --config "$t/config.json" > "$t/out.jsonl" 2>"$t/err.txt" &
pid=$!; sleep 7; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

# (a) a conditional request WAS sent for reviews on tick2+ (IF-NONE-MATCH marker).
ge1 "a: conditional If-None-Match sent for reviews" "$(num "$(grep -cF "$INM" "$t/calls.log" 2>/dev/null || true)")"
# (b) etags.json cached E1 for the reviews endpoint after the 200 tick.
ETAGS="$t/test-repo/etags.json"
if [ -f "$ETAGS" ]; then
  assert_eq "b: etag E1 cached for reviews" '"E1"' "$(jq -r '.["/repos/test/repo/pulls/1/reviews"].etag // empty' "$ETAGS" 2>/dev/null)"
else
  FAIL=$((FAIL+1)); FAILED+=("b: etags.json missing")
fi
# (c) DECISIVE: the conditional LIST 304s were SERVED FROM CACHE, not raised ->
#     NO bridge-status:degraded. A raise-on-rc (BLOCKER-1) bug degrades after the
#     threshold; this assertion cannot pass with the bug present.
assert_eq "c: no degraded (list 304 served cached)" 0 "$(num "$(grep '"type":"bridge-status"' "$t/out.jsonl" 2>/dev/null | grep -c 'degraded' || true)")"
# (d) the 304 serves the same cached review id -> no NEW pr-review emit; no crash.
assert_eq "d: no duplicate pr-review on 304" 0 "$(num "$(grep -c '"type":"pr-review"' "$t/out.jsonl" 2>/dev/null || true)")"
assert_eq "d: no python traceback" 0 "$(num "$(grep -c 'Traceback' "$t/err.txt" 2>/dev/null || true)")"
rm -rf "$t"

# ---- (e) malformed -i headers -> observable bare-GET fallback returns the body ----
t2=$(mktemp -d); mkdir -p "$t2/bin"; cp "$SHIM" "$t2/bin/gh"; chmod +x "$t2/bin/gh"
printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t2/config.json"
printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"s1"}}]\n' > "$t2/open.json"
printf '[{"id":100,"state":"COMMENTED","body":"hi","html_url":"https://example.com/pr/1#r-100","user":{"login":"alice"}}]\n' > "$t2/reviews.json"
PATH="$t2/bin:$PATH" WOW_GH_RESPONSE_FILE="$t2/open.json" WOW_GH_REVIEWS_FILE="$t2/reviews.json" \
  WOW_GH_MALFORMED_HEADERS=1 WOW_GH_CALL_LOG="$t2/calls.log" \
  python3 "$BRIDGE" --config "$t2/config.json" > "$t2/out.jsonl" 2>"$t2/err.txt" &
pid2=$!; sleep 4; kill -TERM "$pid2" 2>/dev/null; wait "$pid2" 2>/dev/null
assert_eq "e: malformed -> no crash" 0 "$(num "$(grep -c 'Traceback' "$t2/err.txt" 2>/dev/null || true)")"
# the bare fallback actually RETURNED the body -> the reviews cursor was populated.
assert_eq "e: bare fallback returned body (cursor populated)" 100 "$(num "$(jq -r '.last_review_id // empty' "$t2/test-repo/pr-1.cursor" 2>/dev/null)")"
# and it was a NON-conditional (plain) reviews fetch (observable bare fallback).
ge1 "e: observable bare reviews fetch" "$(num "$(grep -cxF '/repos/test/repo/pulls/1/reviews' "$t2/calls.log" 2>/dev/null || true)")"
rm -rf "$t2"

echo "github-bridge-etag-conditional: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
