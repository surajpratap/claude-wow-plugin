#!/usr/bin/env bash
# Story 012 / Section H — sprint dispatch graph regression test.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/sprint-graph-next-dispatchable.sh"

if [ ! -f "$HELPER" ]; then
  echo "FATAL: missing helper at $HELPER" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

# Case 1: linear chain A → B → C; only A dispatchable initially.
case_linear_initial() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-t","status":"active","concurrency_limit":3,
 "items":[
   {"id":"A","story":"a.md","status":"pending","depends_on":[]},
   {"id":"B","story":"b.md","status":"pending","depends_on":["A"]},
   {"id":"C","story":"c.md","status":"pending","depends_on":["B"]}
 ]}
EOF
  local out; out=$(bash "$HELPER" "$tmp/m.json")
  assert_eq "linear chain initial: only A dispatchable" "A" "$out"
  rm -rf "$tmp"
}

# Case 2: linear chain after A merged → only B dispatchable.
case_linear_after_a() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-t","status":"active","concurrency_limit":3,
 "items":[
   {"id":"A","story":"a.md","status":"merged","depends_on":[]},
   {"id":"B","story":"b.md","status":"pending","depends_on":["A"]},
   {"id":"C","story":"c.md","status":"pending","depends_on":["B"]}
 ]}
EOF
  local out; out=$(bash "$HELPER" "$tmp/m.json")
  assert_eq "after A merged: only B dispatchable" "B" "$out"
  rm -rf "$tmp"
}

# Case 3: diamond A → B, A → C, B+C → D; after A merged, B+C in parallel.
case_diamond_after_a() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-t","status":"active","concurrency_limit":3,
 "items":[
   {"id":"A","story":"a.md","status":"merged","depends_on":[]},
   {"id":"B","story":"b.md","status":"pending","depends_on":["A"]},
   {"id":"C","story":"c.md","status":"pending","depends_on":["A"]},
   {"id":"D","story":"d.md","status":"pending","depends_on":["B","C"]}
 ]}
EOF
  local out; out=$(bash "$HELPER" "$tmp/m.json")
  # B and C should both come back, in manifest order
  assert_eq "diamond after A: B then C" "$(printf 'B\nC')" "$out"
  rm -rf "$tmp"
}

# Case 4: concurrency cap of 1 on 3 independent items → only one dispatchable.
case_concurrency_cap() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-t","status":"active","concurrency_limit":1,
 "items":[
   {"id":"A","story":"a.md","status":"pending","depends_on":[]},
   {"id":"B","story":"b.md","status":"pending","depends_on":[]},
   {"id":"C","story":"c.md","status":"pending","depends_on":[]}
 ]}
EOF
  local out; out=$(bash "$HELPER" "$tmp/m.json")
  assert_eq "concurrency=1 on 3 independent: only A" "A" "$out"
  rm -rf "$tmp"
}

# Case 5: in-flight items count against concurrency.
case_inflight_consumes_slots() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-t","status":"active","concurrency_limit":2,
 "items":[
   {"id":"A","story":"a.md","status":"in-review","depends_on":[]},
   {"id":"B","story":"b.md","status":"dispatched","depends_on":[]},
   {"id":"C","story":"c.md","status":"pending","depends_on":[]}
 ]}
EOF
  local out; out=$(bash "$HELPER" "$tmp/m.json")
  assert_eq "concurrency=2 with 2 in-flight: nothing dispatchable" "" "$out"
  rm -rf "$tmp"
}

# Case 6 (revised in v2.20.0): stacked items can dispatch when parent is dispatched
# AND parent's plan_approved_at is set. Without plan_approved_at, the child stays
# gated (sprint mode behavior change in v2.20.0 — eliminates version-literal cascade
# conflicts by deferring child branch creation until parent has commits on its branch).
case_stacked_on_dispatched_parent() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-t","status":"active","concurrency_limit":3,
 "items":[
   {"id":"A","story":"a.md","status":"dispatched","branch":"feat/A","plan_approved_at":"2026-05-01T12:00:00Z","depends_on":[]},
   {"id":"B","story":"b.md","status":"pending","depends_on":["A"],"stacked_on":"feat/A"}
 ]}
EOF
  local out; out=$(bash "$HELPER" "$tmp/m.json")
  # A is in-flight (dispatched) so it counts against slots; B is stacked AND parent's plan_approved_at is set.
  # concurrency_limit=3, 1 in-flight, 2 slots free; B is dispatchable.
  assert_eq "stacked-on-dispatched-parent: B dispatchable" "B" "$out"
  rm -rf "$tmp"
}

case_linear_initial
case_linear_after_a
case_diamond_after_a
case_concurrency_cap
case_inflight_consumes_slots
case_stacked_on_dispatched_parent

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
