#!/usr/bin/env bash
# Story 164 — BEHAVIORAL (not shape). Four cases drive the REAL run.py / gh-shim
# (no Python monkeypatch), asserting against emitted events + the gh-shim
# call-log:
#   A  finalize + stays gone : exactly ONE merge pr-state, ONE-shot targeted
#        fetch, cursor finalized:true, and ZERO PR1 fan-out (reviews/comments/
#        check-suites) after finalization (AC2).
#   B  reopen                : merge then merged->ready_for_review, finalized
#        CLEARED, fan-out RESUMES after reopen (AC3).
#   C  per_page overflow guard: PR1 absent from page-1 list but the targeted
#        fetch returns OPEN -> NO terminal event, NOT finalized (Notes guard).
#   D  harness self-check    : `gh api -i -H 'If-None-Match: ...' <path>` skips
#        -i AND -H, dispatches by the real path, logs the real path (not -H),
#        and WOW_GH_STATUS_LIST drives a 200->304 sequence + ETag header — the
#        capability AC4(ii) ships for stories 165/167 (proves it's not inert).
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

count_to()  { grep '"type":"pr-state"' "$1" 2>/dev/null | while IFS= read -r l; do printf '%s' "$l" | jq -r '.payload|fromjson|.to_state'; done | grep -c "^$2\$" || true; }
count_tr()  { grep '"type":"pr-state"' "$1" 2>/dev/null | while IFS= read -r l; do printf '%s' "$l" | jq -r '.payload|fromjson|"\(.from_state)->\(.to_state)"'; done | grep -c "^$2\$" || true; }
fin_flag()  { jq -r '.finalized // empty' "$1" 2>/dev/null; }

setup_common() {
  local t; t=$(mktemp -d); mkdir -p "$t/bin"
  cp "$SHIM" "$t/bin/gh"; chmod +x "$t/bin/gh"
  printf '{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}\n' > "$t/config.json"
  printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"abc123"}}]\n' > "$t/open.json"
  printf '[]\n' > "$t/gone.json"
  printf '[{"id":100,"state":"COMMENTED","body":"hi","html_url":"https://example.com/pr/1#r-100","user":{"login":"alice"}}]\n' > "$t/reviews.json"
  printf '{"number":1,"state":"closed","draft":false,"merged_at":"2026-05-29T16:00:00Z","merged_by":{"login":"carol"},"html_url":"https://example.com/pr/1"}\n' > "$t/detail-merged.json"
  printf '{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"abc123"}}\n' > "$t/detail-open.json"
  printf '%s' "$t"
}

run_bridge() { # $1 tmp  $2 detail-file-basename  $3 sleep-secs
  local t="$1" det="$2" s="$3"
  : > "$t/calls.log"; : > "$t/out.jsonl"; rm -f "$t/lc"
  PATH="$t/bin:$PATH" \
    WOW_GH_RESPONSE_LIST="$t/list.txt" WOW_GH_COUNTER_FILE="$t/lc" \
    WOW_GH_PR_DETAIL_FILE="$t/$det" \
    WOW_GH_REVIEWS_FILE="$t/reviews.json" \
    WOW_GH_CALL_LOG="$t/calls.log" \
    python3 "$BRIDGE" --config "$t/config.json" > "$t/out.jsonl" 2>"$t/err.txt" &
  local pid=$!; sleep "$s"; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

# ---- Case A: finalize + stays gone ----------------------------------------
caseA() {
  local t; t=$(setup_common)
  : > "$t/list.txt"; echo "$t/open.json" >> "$t/list.txt"
  for _ in $(seq 1 20); do echo "$t/gone.json" >> "$t/list.txt"; done
  run_bridge "$t" detail-merged.json 8
  assert_eq "A: one merge pr-state" 1 "$(num "$(count_to "$t/out.jsonl" merged)")"
  assert_eq "A: one-shot targeted fetch" 1 "$(num "$(grep -cxF '/repos/test/repo/pulls/1' "$t/calls.log" 2>/dev/null || true)")"
  assert_eq "A: cursor finalized=true" "true" "$(fin_flag "$t/test-repo/pr-1.cursor")"
  # AC1 — the bridge actually QUERIES state=open (observed via the call-log, which
  # records the full path+query). Guards against a silent revert to state=all
  # (T testability-concern: the shim dispatches */pulls?* regardless of query).
  ge1 "A: lists state=open (AC1)" "$(num "$(grep -cF 'pulls?state=open' "$t/calls.log" 2>/dev/null || true)")"
  assert_eq "A: never lists state=all (AC1)" 0 "$(num "$(grep -cF 'state=all' "$t/calls.log" 2>/dev/null || true)")"
  local fl after
  fl=$(grep -nxF '/repos/test/repo/pulls/1' "$t/calls.log" | head -1 | cut -d: -f1)
  after=$(awk -v A="${fl:-0}" 'NR>A' "$t/calls.log" | grep -cE '/pulls/1/(reviews|comments)|/issues/1/comments|/check-suites' || true)
  assert_eq "A: 0 PR1 fan-out after finalize" 0 "$(num "$after")"
  rm -rf "$t"
}

# ---- Case B: reopen --------------------------------------------------------
caseB() {
  local t; t=$(setup_common)
  : > "$t/list.txt"; printf '%s\n' "$t/open.json" "$t/gone.json" "$t/gone.json" >> "$t/list.txt"
  for _ in $(seq 1 20); do echo "$t/open.json" >> "$t/list.txt"; done
  run_bridge "$t" detail-merged.json 9
  assert_eq "B: one merge pr-state" 1 "$(num "$(count_to "$t/out.jsonl" merged)")"
  assert_eq "B: reopen merged->ready_for_review" 1 "$(num "$(count_tr "$t/out.jsonl" 'merged->ready_for_review')")"
  assert_eq "B: finalized cleared on reopen" "" "$(fin_flag "$t/test-repo/pr-1.cursor")"
  local fl resumed
  fl=$(grep -nxF '/repos/test/repo/pulls/1' "$t/calls.log" | head -1 | cut -d: -f1)
  resumed=$(awk -v A="${fl:-0}" 'NR>A' "$t/calls.log" | grep -c '/pulls/1/reviews' || true)
  ge1 "B: fan-out resumes after reopen" "$(num "$resumed")"
  rm -rf "$t"
}

# ---- Case C: per_page overflow guard (paged-out but still OPEN) ------------
caseC() {
  local t; t=$(setup_common)
  : > "$t/list.txt"; echo "$t/open.json" >> "$t/list.txt"
  for _ in $(seq 1 20); do echo "$t/gone.json" >> "$t/list.txt"; done
  run_bridge "$t" detail-open.json 6   # absent from list, but detail says OPEN
  assert_eq "C: no merged event" 0 "$(num "$(count_to "$t/out.jsonl" merged)")"
  assert_eq "C: no closed event"  0 "$(num "$(count_to "$t/out.jsonl" closed)")"
  assert_eq "C: not falsely finalized" "" "$(fin_flag "$t/test-repo/pr-1.cursor")"
  rm -rf "$t"
}

# ---- Case D: harness self-check (-i + -H skip, sequenced status, ETag) -----
caseD() {
  local t; t=$(mktemp -d); mkdir -p "$t/bin"
  cp "$SHIM" "$t/bin/gh"; chmod +x "$t/bin/gh"
  printf '[]\n' > "$t/resp.json"
  printf '200\n304\n' > "$t/status.txt"
  local o1 o2
  o1=$(PATH="$t/bin:$PATH" WOW_GH_RESPONSE_FILE="$t/resp.json" WOW_GH_STATUS_LIST="$t/status.txt" WOW_GH_STATUS_COUNTER="$t/sc" WOW_GH_ETAG='"e1"' WOW_GH_CALL_LOG="$t/cl" \
        gh api -i -H 'If-None-Match: "e1"' '/repos/test/repo/pulls?state=open')
  o2=$(PATH="$t/bin:$PATH" WOW_GH_RESPONSE_FILE="$t/resp.json" WOW_GH_STATUS_LIST="$t/status.txt" WOW_GH_STATUS_COUNTER="$t/sc" WOW_GH_ETAG='"e1"' WOW_GH_CALL_LOG="$t/cl" \
        gh api -i -H 'If-None-Match: "e1"' '/repos/test/repo/pulls?state=open')
  assert_eq "D: 1st status 200" 1 "$(num "$(printf '%s' "$o1" | grep -c 'HTTP/2.0 200' || true)")"
  assert_eq "D: 2nd status 304" 1 "$(num "$(printf '%s' "$o2" | grep -c 'HTTP/2.0 304' || true)")"
  assert_eq "D: ETag header on 1st" 1 "$(num "$(printf '%s' "$o1" | grep -c 'ETag:' || true)")"
  assert_eq "D: real path dispatched+logged (x2)" 2 "$(num "$(grep -cF 'pulls?state=open' "$t/cl" 2>/dev/null || true)")"
  assert_eq "D: no -H leaked into call-log" 0 "$(num "$(grep -cxF -- '-H' "$t/cl" 2>/dev/null || true)")"
  rm -rf "$t"
}

caseA; caseB; caseC; caseD

echo "github-bridge-poll-state-open: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
