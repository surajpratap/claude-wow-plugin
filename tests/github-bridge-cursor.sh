#!/usr/bin/env bash
# Verify bridge/github/run.py cursor lifecycle:
#   - First observation populates the cursor without emitting pr-state.
#   - State transitions emit one pr-state per transition.
#   - Restart against a steady-state PR (cursor matches) emits zero pr-state.

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

count_pr_state() {
  if [ -f "$1" ]; then
    grep -c '"type":"pr-state"' "$1" || true
  else
    printf '0\n'
  fi
}

tmp="$(mktemp -d)"
mkdir -p "$tmp/bin"
cp "$SHIM" "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

cat > "$tmp/draft.json" <<'EOF'
[{"number":1,"state":"open","draft":true,"merged_at":null,"html_url":"https://example.com/pr/1"}]
EOF
cat > "$tmp/ready.json" <<'EOF'
[{"number":1,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/1"}]
EOF
cat > "$tmp/merged.json" <<'EOF'
[{"number":1,"state":"closed","draft":false,"merged_at":"2026-04-30T08:00:00Z","html_url":"https://example.com/pr/1","merged_by":{"login":"alice"}}]
EOF

# Sequence: draft, draft (no-op), ready_for_review, merged. Four polling
# cycles total. polling_interval_sec=1 → run for ~5s with margin.
{
  echo "$tmp/draft.json"
  echo "$tmp/draft.json"
  echo "$tmp/ready.json"
  echo "$tmp/merged.json"
} > "$tmp/list.txt"

cat > "$tmp/config.json" <<EOF
{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}
EOF

PATH="$tmp/bin:$PATH" \
  WOW_GH_RESPONSE_LIST="$tmp/list.txt" \
  WOW_GH_COUNTER_FILE="$tmp/counter" \
  python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out1.jsonl" 2>"$tmp/err1.txt" &
pid=$!
sleep 5
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

# Expect exactly two pr-state emits: draft→ready_for_review, ready_for_review→merged.
pr_state_count=$(count_pr_state "$tmp/out1.jsonl")
pr_state_count=$(printf '%s' "$pr_state_count" | tr -d '[:space:]')
assert_eq "pr-state event count after sequence" 2 "$pr_state_count"

# Inspect the two emitted pr-state events.
events=$(grep '"type":"pr-state"' "$tmp/out1.jsonl" 2>/dev/null || true)
first_event=$(printf '%s' "$events" | sed -n '1p')
second_event=$(printf '%s' "$events" | sed -n '2p')

if [ -n "$first_event" ]; then
  assert_eq "1st pr-state from_state" "draft" "$(printf '%s' "$first_event" | jq -r '.payload | fromjson | .from_state')"
  assert_eq "1st pr-state to_state" "ready_for_review" "$(printf '%s' "$first_event" | jq -r '.payload | fromjson | .to_state')"
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("missing first pr-state event")
fi

if [ -n "$second_event" ]; then
  assert_eq "2nd pr-state from_state" "ready_for_review" "$(printf '%s' "$second_event" | jq -r '.payload | fromjson | .from_state')"
  assert_eq "2nd pr-state to_state" "merged" "$(printf '%s' "$second_event" | jq -r '.payload | fromjson | .to_state')"
  assert_eq "2nd pr-state actor" "alice" "$(printf '%s' "$second_event" | jq -r '.payload | fromjson | .actor')"
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("missing second pr-state event")
fi

# Cursor should reflect the final merged state.
cursor_path="$tmp/test-repo/pr-1.cursor"
if [ -f "$cursor_path" ]; then
  assert_eq "final cursor.state" "merged" "$(jq -r '.state' "$cursor_path")"
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("cursor file missing at $cursor_path")
fi

# Restart: feed only the merged response. Cursor matches → zero pr-state events.
echo "$tmp/merged.json" > "$tmp/list2.txt"
PATH="$tmp/bin:$PATH" \
  WOW_GH_RESPONSE_LIST="$tmp/list2.txt" \
  WOW_GH_COUNTER_FILE="$tmp/counter2" \
  python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out2.jsonl" 2>"$tmp/err2.txt" &
pid=$!
sleep 2
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

pr_state_count2=$(count_pr_state "$tmp/out2.jsonl")
pr_state_count2=$(printf '%s' "$pr_state_count2" | tr -d '[:space:]')
assert_eq "pr-state event count after restart with matching cursor" 0 "$pr_state_count2"

rm -rf "$tmp"

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
