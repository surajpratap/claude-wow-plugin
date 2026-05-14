#!/usr/bin/env bash
# Verify bridge/github/run.py emits ci-check events on suite state
# transitions and populates last_seen_check_states (a dict) without
# emitting on first observation. The dict keyed by suite-id (vs a max-id
# scalar) is required by story AC: a single suite transitions
# queued → in_progress → completed on the same id; a max-id approach
# would silently miss the second/third transitions.

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

count_type() {
  local file="$1"
  local typ="$2"
  if [ -f "$file" ]; then
    grep -c "\"type\":\"$typ\"" "$file" || true
  else
    printf '0\n'
  fi
}

setup_tmp() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cp "$SHIM" "$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1","head":{"sha":"abc123"}}]\n' \
    > "$tmp/pulls.json"
  cat > "$tmp/config.json" <<EOF
{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}
EOF
  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# Case 1: no check suites → 0 ci-check events.
# ---------------------------------------------------------------------------
case_no_suites() {
  local tmp; tmp="$(setup_tmp)"
  echo '{"check_suites":[]}' > "$tmp/empty-suites.json"
  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_CHECK_SUITES_FILE="$tmp/empty-suites.json" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(count_type "$tmp/out.jsonl" "ci-check")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case1: no check suites → 0 ci-check events" 0 "$n"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 2: first observation populates last_seen_check_states without emit.
# ---------------------------------------------------------------------------
case_first_obs_populate() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/one-suite.json" <<'EOF'
{"check_suites":[{"id":777,"status":"queued","conclusion":null,"app":{"slug":"github-actions"}}]}
EOF
  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_CHECK_SUITES_FILE="$tmp/one-suite.json" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(count_type "$tmp/out.jsonl" "ci-check")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case2: first observation → 0 ci-check events (populate only)" 0 "$n"

  local cursor="$tmp/test-repo/pr-1.cursor"
  if [ -f "$cursor" ]; then
    local status; status=$(jq -r '.last_seen_check_states["777"].status // empty' "$cursor")
    assert_eq "case2: cursor.last_seen_check_states populated for suite 777" "queued" "$status"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case2: cursor file missing")
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 3: queued → in_progress → completed/success transitions on the same
# suite id. Bridge populates on tick 1 (no emit), emits on ticks 2 + 3 →
# 2 ci-check events total (the populate is not an event).
# ---------------------------------------------------------------------------
case_success_transitions() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/queued.json"      <<'EOF'
{"check_suites":[{"id":888,"status":"queued","conclusion":null,"app":{"slug":"github-actions"}}]}
EOF
  cat > "$tmp/in-progress.json" <<'EOF'
{"check_suites":[{"id":888,"status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}]}
EOF
  cat > "$tmp/completed.json"   <<'EOF'
{"check_suites":[{"id":888,"status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}
EOF
  : > "$tmp/suites-list.txt"
  echo "$tmp/queued.json"      >> "$tmp/suites-list.txt"
  echo "$tmp/in-progress.json" >> "$tmp/suites-list.txt"
  echo "$tmp/completed.json"   >> "$tmp/suites-list.txt"
  echo "$tmp/completed.json"   >> "$tmp/suites-list.txt"

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_CHECK_SUITES_LIST="$tmp/suites-list.txt" \
    WOW_GH_CHECK_SUITES_COUNTER="$tmp/suites-counter" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 5
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(count_type "$tmp/out.jsonl" "ci-check")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case3: ci-check event count (transitions emit; populate doesn't)" 2 "$n"

  local first; first=$(grep '"type":"ci-check"' "$tmp/out.jsonl" 2>/dev/null | sed -n '1p')
  local second; second=$(grep '"type":"ci-check"' "$tmp/out.jsonl" 2>/dev/null | sed -n '2p')
  if [ -n "$first" ]; then
    assert_eq "case3: 1st ci-check status" "in_progress" "$(printf '%s' "$first" | jq -r '.payload | fromjson | .status')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3: missing 1st ci-check event")
  fi
  if [ -n "$second" ]; then
    assert_eq "case3: 2nd ci-check status" "completed" "$(printf '%s' "$second" | jq -r '.payload | fromjson | .status')"
    assert_eq "case3: 2nd ci-check conclusion" "success" "$(printf '%s' "$second" | jq -r '.payload | fromjson | .conclusion')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3: missing 2nd ci-check event")
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 4: queued → in_progress → completed/failure on the same suite id.
# 2 ci-check events; last with conclusion=failure.
# ---------------------------------------------------------------------------
case_failure_transitions() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/queued.json"      <<'EOF'
{"check_suites":[{"id":999,"status":"queued","conclusion":null,"app":{"slug":"github-actions"}}]}
EOF
  cat > "$tmp/in-progress.json" <<'EOF'
{"check_suites":[{"id":999,"status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}]}
EOF
  cat > "$tmp/failed.json"      <<'EOF'
{"check_suites":[{"id":999,"status":"completed","conclusion":"failure","app":{"slug":"github-actions"}}]}
EOF
  : > "$tmp/suites-list.txt"
  echo "$tmp/queued.json"      >> "$tmp/suites-list.txt"
  echo "$tmp/in-progress.json" >> "$tmp/suites-list.txt"
  echo "$tmp/failed.json"      >> "$tmp/suites-list.txt"
  echo "$tmp/failed.json"      >> "$tmp/suites-list.txt"

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_CHECK_SUITES_LIST="$tmp/suites-list.txt" \
    WOW_GH_CHECK_SUITES_COUNTER="$tmp/suites-counter" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 5
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(count_type "$tmp/out.jsonl" "ci-check")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case4: ci-check event count (failure path)" 2 "$n"

  local last; last=$(grep '"type":"ci-check"' "$tmp/out.jsonl" 2>/dev/null | tail -1)
  if [ -n "$last" ]; then
    assert_eq "case4: last ci-check conclusion" "failure" "$(printf '%s' "$last" | jq -r '.payload | fromjson | .conclusion')"
    assert_eq "case4: last ci-check suite name" "github-actions" "$(printf '%s' "$last" | jq -r '.payload | fromjson | .suite')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case4: missing failure ci-check event")
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 5: no event when suite status unchanged. Two ticks return the same
# suite at the same {status, conclusion} — populate on tick 1, no emit on
# tick 2.
# ---------------------------------------------------------------------------
case_no_event_unchanged() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/stable.json" <<'EOF'
{"check_suites":[{"id":1010,"status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}
EOF
  : > "$tmp/suites-list.txt"
  echo "$tmp/stable.json" >> "$tmp/suites-list.txt"
  echo "$tmp/stable.json" >> "$tmp/suites-list.txt"
  echo "$tmp/stable.json" >> "$tmp/suites-list.txt"

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_CHECK_SUITES_LIST="$tmp/suites-list.txt" \
    WOW_GH_CHECK_SUITES_COUNTER="$tmp/suites-counter" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 4
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(count_type "$tmp/out.jsonl" "ci-check")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case5: stable suite → 0 ci-check events" 0 "$n"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 6: multi-suite per PR. Two suites with different IDs both populate on
# tick 1; tick 2 transitions only suite A → exactly one event fires.
# ---------------------------------------------------------------------------
case_multi_suite() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/two-queued.json" <<'EOF'
{"check_suites":[
  {"id":2001,"status":"queued","conclusion":null,"app":{"slug":"github-actions"}},
  {"id":2002,"status":"queued","conclusion":null,"app":{"slug":"circleci"}}
]}
EOF
  cat > "$tmp/one-changed.json" <<'EOF'
{"check_suites":[
  {"id":2001,"status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}},
  {"id":2002,"status":"queued","conclusion":null,"app":{"slug":"circleci"}}
]}
EOF
  : > "$tmp/suites-list.txt"
  echo "$tmp/two-queued.json"   >> "$tmp/suites-list.txt"
  echo "$tmp/one-changed.json"  >> "$tmp/suites-list.txt"
  echo "$tmp/one-changed.json"  >> "$tmp/suites-list.txt"

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_CHECK_SUITES_LIST="$tmp/suites-list.txt" \
    WOW_GH_CHECK_SUITES_COUNTER="$tmp/suites-counter" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 4
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(count_type "$tmp/out.jsonl" "ci-check")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case6: multi-suite, one transitions → 1 ci-check event" 1 "$n"

  local event; event=$(grep '"type":"ci-check"' "$tmp/out.jsonl" 2>/dev/null | head -1)
  if [ -n "$event" ]; then
    assert_eq "case6: emitted suite name (the transitioning one)" "github-actions" "$(printf '%s' "$event" | jq -r '.payload | fromjson | .suite')"
  fi

  rm -rf "$tmp"
}

case_no_suites
case_first_obs_populate
case_success_transitions
case_failure_transitions
case_no_event_unchanged
case_multi_suite

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
