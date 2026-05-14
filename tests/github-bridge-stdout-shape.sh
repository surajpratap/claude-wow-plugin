#!/usr/bin/env bash
# Verify bridge/github/run.py emits well-formed JSONL events with the
# expected envelope shape.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$REPO_ROOT/bridge/github/run.py"
SHIM="$REPO_ROOT/tests/fixtures/gh-shim.sh"

if [ ! -f "$BRIDGE" ]; then
  echo "FATAL: $BRIDGE not found" >&2
  exit 2
fi
if [ ! -f "$SHIM" ]; then
  echo "FATAL: $SHIM not found" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 required" >&2
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

assert_match() {
  local name="$1"
  local pattern="$2"
  local actual="$3"
  if printf '%s' "$actual" | grep -qE "$pattern"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (pattern '$pattern' did not match '$actual')")
  fi
}

tmp="$(mktemp -d)"
mkdir -p "$tmp/bin"
cp "$SHIM" "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

# Single canned response with one open PR.
cat > "$tmp/pulls.json" <<'EOF'
[{"number":42,"state":"open","draft":false,"merged_at":null,"html_url":"https://example.com/pr/42"}]
EOF
cat > "$tmp/config.json" <<EOF
{"port": 47823, "repos": ["test/repo"], "polling_interval_sec": 1}
EOF

PATH="$tmp/bin:$PATH" WOW_GH_RESPONSE_FILE="$tmp/pulls.json" \
  python3 "$BRIDGE" --config "$tmp/config.json" > "$tmp/out.jsonl" 2>"$tmp/err.txt" &
pid=$!
sleep 3
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

# Every line is valid JSON.
total_lines=0
valid_lines=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  total_lines=$((total_lines+1))
  if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    valid_lines=$((valid_lines+1))
  fi
done < "$tmp/out.jsonl"
assert_eq "every line parses as JSON" "$total_lines" "$valid_lines"

# Need at least 2 lines (armed at start, stopped at end).
if [ "$total_lines" -ge 2 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("expected at least 2 events, got $total_lines")
fi

first_line=$(head -1 "$tmp/out.jsonl")
last_line=$(tail -1 "$tmp/out.jsonl")

# First event: bridge-status armed.
assert_eq "first.type" "bridge-status" "$(printf '%s' "$first_line" | jq -r '.type')"
assert_eq "first.payload.state" "armed" "$(printf '%s' "$first_line" | jq -r '.payload | fromjson | .state')"

# Last event: bridge-status stopped.
assert_eq "last.type" "bridge-status" "$(printf '%s' "$last_line" | jq -r '.type')"
assert_eq "last.payload.state" "stopped" "$(printf '%s' "$last_line" | jq -r '.payload | fromjson | .state')"

# Every line has the bus envelope shape (ts, from, to, type, payload).
envelope_ok=1
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! printf '%s' "$line" | jq -e 'has("ts") and has("from") and has("to") and has("type") and has("payload")' >/dev/null 2>&1; then
    envelope_ok=0
    break
  fi
done < "$tmp/out.jsonl"
assert_eq "envelope keys present on every line" 1 "$envelope_ok"

# from is github-bridge-<port>, to is manager-*, on every line.
from_ok=1
to_ok=1
while IFS= read -r line; do
  [ -z "$line" ] && continue
  from=$(printf '%s' "$line" | jq -r '.from')
  to=$(printf '%s' "$line" | jq -r '.to')
  case "$from" in
    github-bridge-*) ;;
    *) from_ok=0; break ;;
  esac
  case "$to" in
    manager-\*) ;;
    *) to_ok=0; break ;;
  esac
done < "$tmp/out.jsonl"
assert_eq "from is github-bridge-* on every line" 1 "$from_ok"
assert_eq "to is manager-* on every line" 1 "$to_ok"

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
