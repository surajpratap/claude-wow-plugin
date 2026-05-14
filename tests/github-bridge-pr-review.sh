#!/usr/bin/env bash
# Verify bridge/github/run.py emits pr-review events on transitions and
# populates the cursor without emit on first observation.

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
  printf '[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1"}]\n' \
    > "$tmp/pulls.json"
  cat > "$tmp/config.json" <<EOF
{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}
EOF
  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# Case 1: no reviews → no pr-review events.
# ---------------------------------------------------------------------------
case_no_reviews() {
  local tmp; tmp="$(setup_tmp)"
  echo '[]' > "$tmp/empty-reviews.json"
  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_REVIEWS_FILE="$tmp/empty-reviews.json" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(count_type "$tmp/out.jsonl" "pr-review")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case1: no reviews → 0 pr-review events" 0 "$n"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 2: first observation populates last_review_id without emit.
# ---------------------------------------------------------------------------
case_first_obs_populate() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/one-review.json" <<'EOF'
[{"id":100,"state":"COMMENTED","body":"first comment","html_url":"https://example.com/pr/1#review-100","user":{"login":"alice"}}]
EOF
  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_REVIEWS_FILE="$tmp/one-review.json" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local n
  n=$(count_type "$tmp/out.jsonl" "pr-review")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case2: first observation → 0 pr-review events (populate only)" 0 "$n"

  local cursor="$tmp/test-repo/pr-1.cursor"
  if [ -f "$cursor" ]; then
    local lrid; lrid=$(jq -r '.last_review_id // empty' "$cursor")
    assert_eq "case2: cursor.last_review_id populated" 100 "$lrid"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case2: cursor file missing")
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 3: new reviews after a populated cursor → emits in id order.
# ---------------------------------------------------------------------------
case_new_reviews_emit() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/one-review.json" <<'EOF'
[{"id":100,"state":"COMMENTED","body":"first","html_url":"https://example.com/pr/1#review-100","user":{"login":"alice"}}]
EOF
  cat > "$tmp/three-reviews.json" <<'EOF'
[{"id":100,"state":"COMMENTED","body":"first","html_url":"https://example.com/pr/1#review-100","user":{"login":"alice"}},
 {"id":200,"state":"CHANGES_REQUESTED","body":"please fix","html_url":"https://example.com/pr/1#review-200","user":{"login":"bob"}},
 {"id":300,"state":"APPROVED","body":"lgtm","html_url":"https://example.com/pr/1#review-300","user":{"login":"carol"}}]
EOF
  : > "$tmp/reviews-list.txt"
  echo "$tmp/one-review.json" >> "$tmp/reviews-list.txt"
  echo "$tmp/three-reviews.json" >> "$tmp/reviews-list.txt"
  echo "$tmp/three-reviews.json" >> "$tmp/reviews-list.txt"

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
    WOW_GH_REVIEWS_LIST="$tmp/reviews-list.txt" \
    WOW_GH_REVIEWS_COUNTER="$tmp/reviews-counter" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 4
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  # Bridge sees: tick1 = one review (populate, no emit), tick2 = three (emit two new), tick3 = three (no new).
  local n
  n=$(count_type "$tmp/out.jsonl" "pr-review")
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  assert_eq "case3: pr-review event count" 2 "$n"

  local events
  events=$(grep '"type":"pr-review"' "$tmp/out.jsonl" 2>/dev/null || true)
  local first; first=$(printf '%s' "$events" | sed -n '1p')
  local second; second=$(printf '%s' "$events" | sed -n '2p')

  if [ -n "$first" ]; then
    assert_eq "case3: 1st pr-review state" "changes_requested" "$(printf '%s' "$first" | jq -r '.payload | fromjson | .state')"
    assert_eq "case3: 1st pr-review reviewer" "bob" "$(printf '%s' "$first" | jq -r '.payload | fromjson | .reviewer')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3: missing first pr-review")
  fi
  if [ -n "$second" ]; then
    assert_eq "case3: 2nd pr-review state" "approved" "$(printf '%s' "$second" | jq -r '.payload | fromjson | .state')"
    assert_eq "case3: 2nd pr-review reviewer" "carol" "$(printf '%s' "$second" | jq -r '.payload | fromjson | .reviewer')"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3: missing second pr-review")
  fi

  rm -rf "$tmp"
}

case_no_reviews
case_first_obs_populate
case_new_reviews_emit

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
