#!/usr/bin/env bash
# Story 102 — sprint manifest `contract` field validation.
# Each item's optional `contract` is null | {owner, name} (non-empty strings);
# contract.owner must reference a real manifest item id.

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

# mk_manifest <contract-json | OMIT>
# Builds a 2-item manifest (ids 022, 021); item 021 carries `"contract": <arg>`
# unless the arg is the literal OMIT (then 021 has no contract field at all).
mk_manifest() {
  local arg="$1" d line
  d=$(mktemp -d)
  if [ "$arg" = "OMIT" ]; then
    line=""
  else
    line="      \"contract\": $arg,"
  fi
  cat > "$d/m.json" <<EOF
{
  "id": "2026-05-18-test",
  "started_ts": "2026-05-18T00:00:00Z",
  "started_by": "human",
  "status": "active",
  "concurrency_limit": 3,
  "auto_merge": true,
  "items": [
    {"id": "022", "story": "implementations/stories/022-x.md", "status": "pending", "depends_on": []},
    {
      "id": "021",
      "story": "implementations/stories/021-y.md",
      "status": "pending",
      "depends_on": [],
$line
      "branch": "feat/021-y"
    }
  ],
  "rebases": []
}
EOF
  echo "$d/m.json"
}

check() {
  # $1 = case name, $2 = expected exit, $3 = contract arg
  local m; m=$(mk_manifest "$3")
  bash "$VALIDATOR" "$m" >/dev/null 2>&1
  assert_exit "$1" "$2" "$?"
  rm -rf "$(dirname "$m")"
}

# --- valid ---
check "valid-contract-null"        0 'null'
check "valid-contract-object"      0 '{"owner":"022","name":"workspace-id contract"}'
check "valid-contract-omitted"     0 OMIT

# --- invalid: cross-reference ---
check "invalid-owner-nonexistent"  1 '{"owner":"999","name":"x"}'

# --- invalid: missing required fields ---
check "invalid-missing-name"       1 '{"owner":"022"}'
check "invalid-missing-owner"      1 '{"name":"x"}'

# --- invalid: shape violations ---
check "invalid-empty-string"       1 '""'
check "invalid-number"             1 '7'
check "invalid-owner-not-string"   1 '{"owner":21,"name":"x"}'
check "invalid-name-not-string"    1 '{"owner":"022","name":7}'

echo "sprint-manifest-contract-field: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
