#!/usr/bin/env bash
# Verify bridge/github/run.py handles multi-repo configs: independent
# per-repo cursors, correct repo field on every event, and failure
# isolation (one repo degrading doesn't suppress emits from another).

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

setup_tmp() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cp "$SHIM" "$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  cat > "$tmp/config.json" <<EOF
{"port": 47823, "repos": ["org/repoA", "org/repoB"], "polling_interval_sec": 1}
EOF
  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# Case 1: independent per-repo cursors. Repo A and Repo B each have one PR
# with distinct numbers / urls. After two ticks, each repo's cursor file
# exists separately and pr-state events on transitions carry the correct
# `repo` field.
# ---------------------------------------------------------------------------
case_independent_cursors() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/repoA-open.json" <<'EOF'
[{"number":11,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/repoA/pr/11","head":{"sha":"aaa1"}}]
EOF
  cat > "$tmp/repoB-open.json" <<'EOF'
[{"number":22,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/repoB/pr/22","head":{"sha":"bbb2"}}]
EOF
  cat > "$tmp/repoA-merged.json" <<'EOF'
[{"number":11,"state":"closed","draft":false,"merged_at":"2026-04-30T10:00:00Z","html_url":"https://example.com/repoA/pr/11","merged_by":{"login":"alice"},"head":{"sha":"aaa1"}}]
EOF
  cat > "$tmp/repoB-merged.json" <<'EOF'
[{"number":22,"state":"closed","draft":false,"merged_at":"2026-04-30T10:01:00Z","html_url":"https://example.com/repoB/pr/22","merged_by":{"login":"bob"},"head":{"sha":"bbb2"}}]
EOF
  # Bridge iterates repos in config order: repoA, repoB. Each tick polls
  # both. So the LIST sequence is: repoA-open, repoB-open, (tick 2) repoA-merged, repoB-merged.
  : > "$tmp/pulls-list.txt"
  echo "$tmp/repoA-open.json"   >> "$tmp/pulls-list.txt"
  echo "$tmp/repoB-open.json"   >> "$tmp/pulls-list.txt"
  echo "$tmp/repoA-merged.json" >> "$tmp/pulls-list.txt"
  echo "$tmp/repoB-merged.json" >> "$tmp/pulls-list.txt"
  echo "$tmp/repoA-merged.json" >> "$tmp/pulls-list.txt"
  echo "$tmp/repoB-merged.json" >> "$tmp/pulls-list.txt"

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_LIST="$tmp/pulls-list.txt" \
    WOW_GH_COUNTER_FILE="$tmp/pulls-counter" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 4
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  # Each repo cursor lives at its own slug dir.
  if [ -f "$tmp/org-repoA/pr-11.cursor" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case1: repoA cursor file missing")
  fi
  if [ -f "$tmp/org-repoB/pr-22.cursor" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case1: repoB cursor file missing")
  fi

  # Two pr-state events expected (one transition per repo).
  local n_state
  n_state=$(grep -c '"type":"pr-state"' "$tmp/out.jsonl" 2>/dev/null || echo 0)
  n_state=$(printf '%s' "$n_state" | tr -d '[:space:]')
  assert_eq "case1: 2 pr-state events emitted (one per repo)" 2 "$n_state"

  # Each event carries the right repo field.
  local got_a got_b
  got_a=$(grep '"type":"pr-state"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | .repo' | grep -c "^org/repoA$" || echo 0)
  got_b=$(grep '"type":"pr-state"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | .repo' | grep -c "^org/repoB$" || echo 0)
  got_a=$(printf '%s' "$got_a" | tr -d '[:space:]')
  got_b=$(printf '%s' "$got_b" | tr -d '[:space:]')
  assert_eq "case1: repoA appears as the repo field on exactly 1 event" 1 "$got_a"
  assert_eq "case1: repoB appears as the repo field on exactly 1 event" 1 "$got_b"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 2: failure isolation. WOW_GH_FAIL_PATH_GLOB fails every gh api
# whose path mentions repoB; repoA continues to succeed and emit
# transitions. The bridge degrades only repoB after threshold ticks.
# ---------------------------------------------------------------------------
case_failure_isolation() {
  local tmp; tmp="$(setup_tmp)"
  cat > "$tmp/repoA-open.json" <<'EOF'
[{"number":33,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/repoA/pr/33","head":{"sha":"aaa3"}}]
EOF
  cat > "$tmp/repoA-merged.json" <<'EOF'
[{"number":33,"state":"closed","draft":false,"merged_at":"2026-04-30T11:00:00Z","html_url":"https://example.com/repoA/pr/33","merged_by":{"login":"alice"},"head":{"sha":"aaa3"}}]
EOF
  : > "$tmp/pulls-list.txt"
  echo "$tmp/repoA-open.json"   >> "$tmp/pulls-list.txt"
  echo "$tmp/repoA-merged.json" >> "$tmp/pulls-list.txt"
  echo "$tmp/repoA-merged.json" >> "$tmp/pulls-list.txt"
  echo "$tmp/repoA-merged.json" >> "$tmp/pulls-list.txt"

  PATH="$tmp/bin:$PATH" \
    WOW_GH_RESPONSE_LIST="$tmp/pulls-list.txt" \
    WOW_GH_COUNTER_FILE="$tmp/pulls-counter" \
    WOW_GH_FAIL_PATH_GLOB="*repoB*" \
    python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
  local pid=$!
  sleep 5
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  # repoA still emits pr-state on its transition.
  local n_state
  n_state=$(grep -c '"type":"pr-state"' "$tmp/out.jsonl" 2>/dev/null || echo 0)
  n_state=$(printf '%s' "$n_state" | tr -d '[:space:]')
  assert_eq "case2: repoA emits pr-state despite repoB failing" 1 "$n_state"

  local repo_field
  repo_field=$(grep '"type":"pr-state"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | .repo' | head -1)
  assert_eq "case2: pr-state's repo field is repoA (not repoB)" "org/repoA" "$repo_field"

  # bridge-status: degraded should fire for repoB after DEGRADATION_THRESHOLD failures.
  local degraded_b
  degraded_b=$(grep '"type":"bridge-status"' "$tmp/out.jsonl" | jq -rc '.payload | fromjson | select(.state == "degraded") | .reason' | grep -c "repoB" || echo 0)
  degraded_b=$(printf '%s' "$degraded_b" | tr -d '[:space:]')
  if [ "$degraded_b" -ge 1 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case2: expected at least 1 'degraded' bridge-status mentioning repoB, got $degraded_b")
  fi

  rm -rf "$tmp"
}

case_independent_cursors
case_failure_isolation

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
