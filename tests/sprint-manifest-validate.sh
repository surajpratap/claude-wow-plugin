#!/usr/bin/env bash
# Story 012 / Section H — sprint manifest validator regression test.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/sprint-manifest-validate.sh"

if [ ! -f "$VALIDATOR" ]; then
  echo "FATAL: missing validator at $VALIDATOR" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILED_CASES=()

assert_exit() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected exit $expected, got $actual)")
  fi
}

assert_contains() {
  local name="$1"; local needle="$2"; local haystack="$3"
  if printf '%s' "$haystack" | grep -q -F "$needle"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected to contain '$needle', got '$haystack')")
  fi
}

run_validator() {
  local manifest="$1"
  bash "$VALIDATOR" "$manifest" 2>&1
  return $?
}

# Case 1: valid manifest → exit 0
case_valid() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{
  "id": "2026-05-01-bridge-hardening",
  "started_ts": "2026-05-01T13:35:00Z",
  "started_by": "human",
  "status": "active",
  "concurrency_limit": 3,
  "auto_merge": true,
  "items": [
    {"id": "022", "story": "implementations/stories/022-x.md", "status": "pending", "depends_on": []},
    {"id": "021", "story": "implementations/stories/021-y.md", "status": "pending", "depends_on": ["022"]}
  ],
  "rebases": []
}
EOF
  local out; out=$(run_validator "$tmp/m.json"); local rc=$?
  assert_exit "valid manifest exits 0" 0 "$rc"
  rm -rf "$tmp"
}

# Case 2: missing id
case_no_id() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"status":"active","concurrency_limit":3,"items":[{"id":"x","story":"s.md","status":"pending"}]}
EOF
  local out; out=$(run_validator "$tmp/m.json"); local rc=$?
  if [ "$rc" -ne 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("missing id should exit non-zero, got 0")
  fi
  assert_contains "missing id diagnostic mentions 'id'" "id" "$out"
  rm -rf "$tmp"
}

# Case 3: bad status enum
case_bad_status() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-x","status":"not-a-status","concurrency_limit":1,"items":[{"id":"a","story":"s.md","status":"pending"}]}
EOF
  local out; out=$(run_validator "$tmp/m.json"); local rc=$?
  if [ "$rc" -ne 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("bad status should exit non-zero"); fi
  assert_contains "bad status diagnostic" "not-a-status" "$out"
  rm -rf "$tmp"
}

# Case 4: depends_on references unknown id
case_unknown_dep() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-x","status":"active","concurrency_limit":1,"items":[{"id":"a","story":"s.md","status":"pending","depends_on":["ghost"]}]}
EOF
  local out; out=$(run_validator "$tmp/m.json"); local rc=$?
  if [ "$rc" -ne 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("unknown dep should exit non-zero"); fi
  assert_contains "unknown dep diagnostic" "ghost" "$out"
  rm -rf "$tmp"
}

# Case 5: spike without alt_story
case_spike_no_alt() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-x","status":"active","concurrency_limit":1,"items":[{"id":"a","story":"s.md","status":"pending","spike":"sp.md"}]}
EOF
  local out; out=$(run_validator "$tmp/m.json"); local rc=$?
  if [ "$rc" -ne 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("spike-without-alt should exit non-zero"); fi
  assert_contains "spike-without-alt diagnostic" "alt_story" "$out"
  rm -rf "$tmp"
}

# Case 6: rebases entry with unknown item id
case_unknown_rebase_item() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-x","status":"active","concurrency_limit":1,"items":[{"id":"a","story":"s.md","status":"pending"}],"rebases":[{"ts":"t","parent":"a","child":"missing","old_sha":"x","new_sha":"y"}]}
EOF
  local out; out=$(run_validator "$tmp/m.json"); local rc=$?
  if [ "$rc" -ne 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("unknown-rebase-child should exit non-zero"); fi
  assert_contains "unknown-rebase-child diagnostic" "missing" "$out"
  rm -rf "$tmp"
}

case_valid
case_no_id
case_bad_status
case_unknown_dep
case_spike_no_alt
case_unknown_rebase_item

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
