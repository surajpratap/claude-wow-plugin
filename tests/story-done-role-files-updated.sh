#!/usr/bin/env bash
# Story 029 — `story-done` payload `role_files_updated` field test.
#
# Asserts the consumer-side jq filter that PP/T use at session start to
# detect role-file modifications since their last session.
#
# Cases:
# 1. Match: story-done with role_files_updated containing self → returned
# 2. Skip: story-done without role_files_updated → not returned
# 3. Skip: story-done with role_files_updated NOT containing self → not returned
# 4. Skip: story-done with role_files_updated containing self but ts <= cutoff → not returned
# 5. Filter type: non-story-done message with role_files_updated payload → not returned
# 6. Multi-match: returns at least one match when multiple are eligible

set -u

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

# Consumer-side jq filter — mirrors what PP/T run at session start.
scan_for_self() {
  local bus="$1" cutoff="$2" self="$3"
  jq -c --arg cutoff "$cutoff" --arg self "$self" '
    select(.type == "story-done")
    | select(.ts > $cutoff)
    | select(.payload.role_files_updated // [] | index($self))
  ' "$bus" 2>/dev/null | head -1
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: match — story-done with role_files_updated containing self.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T08:00:00Z","from":"sd","to":"tester-*","type":"story-done","payload":{"sha":"abc","role_files_updated":["commands/tester.md","commands/manager.md"]}}
EOF
RESULT=$(scan_for_self "$BUS" "2026-05-02T07:00:00Z" "commands/tester.md")
HAS_MATCH=$([ -n "$RESULT" ] && echo "yes" || echo "no")
assert_eq "case-1-match-found" "yes" "$HAS_MATCH"
rm -rf "$DIR"

# Case 2: skip — story-done without role_files_updated payload.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T08:00:00Z","from":"sd","to":"tester-*","type":"story-done","payload":{"sha":"abc"}}
EOF
RESULT=$(scan_for_self "$BUS" "2026-05-02T07:00:00Z" "commands/tester.md")
HAS_MATCH=$([ -n "$RESULT" ] && echo "yes" || echo "no")
assert_eq "case-2-no-payload-field-skipped" "no" "$HAS_MATCH"
rm -rf "$DIR"

# Case 3: skip — role_files_updated present but does NOT contain self.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T08:00:00Z","from":"sd","to":"tester-*","type":"story-done","payload":{"sha":"abc","role_files_updated":["commands/manager.md","commands/senior-developer.md"]}}
EOF
RESULT=$(scan_for_self "$BUS" "2026-05-02T07:00:00Z" "commands/tester.md")
HAS_MATCH=$([ -n "$RESULT" ] && echo "yes" || echo "no")
assert_eq "case-3-self-not-in-list-skipped" "no" "$HAS_MATCH"
rm -rf "$DIR"

# Case 4: skip — message older than cutoff.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T06:00:00Z","from":"sd","to":"tester-*","type":"story-done","payload":{"sha":"abc","role_files_updated":["commands/tester.md"]}}
EOF
RESULT=$(scan_for_self "$BUS" "2026-05-02T07:00:00Z" "commands/tester.md")
HAS_MATCH=$([ -n "$RESULT" ] && echo "yes" || echo "no")
assert_eq "case-4-stale-message-skipped" "no" "$HAS_MATCH"
rm -rf "$DIR"

# Case 5: filter type — non-story-done with payload.role_files_updated.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T08:00:00Z","from":"sd","to":"tester-*","type":"plan-done","payload":{"role_files_updated":["commands/tester.md"]}}
EOF
RESULT=$(scan_for_self "$BUS" "2026-05-02T07:00:00Z" "commands/tester.md")
HAS_MATCH=$([ -n "$RESULT" ] && echo "yes" || echo "no")
assert_eq "case-5-wrong-type-skipped" "no" "$HAS_MATCH"
rm -rf "$DIR"

# Case 6: multi-match — bus has multiple eligible messages, returns ≥ 1.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T08:00:00Z","from":"sd","to":"tester-*","type":"story-done","payload":{"sha":"abc","role_files_updated":["commands/tester.md"]}}
{"ts":"2026-05-02T09:00:00Z","from":"sd","to":"tester-*","type":"story-done","payload":{"sha":"def","role_files_updated":["commands/tester.md","commands/pair-programmer.md"]}}
EOF
COUNT=$(jq -c --arg cutoff "2026-05-02T07:00:00Z" --arg self "commands/tester.md" '
  select(.type == "story-done")
  | select(.ts > $cutoff)
  | select(.payload.role_files_updated // [] | index($self))
' "$BUS" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "case-6-multi-match-count" "2" "$COUNT"
rm -rf "$DIR"

# Case 7: PP self — same filter parameterized for PP's role file.
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
cat > "$BUS" <<'EOF'
{"ts":"2026-05-02T08:00:00Z","from":"sd","to":"pair-programmer-*","type":"story-done","payload":{"role_files_updated":["commands/pair-programmer.md"]}}
EOF
RESULT=$(scan_for_self "$BUS" "2026-05-02T07:00:00Z" "commands/pair-programmer.md")
HAS_MATCH=$([ -n "$RESULT" ] && echo "yes" || echo "no")
assert_eq "case-7-pp-self-match" "yes" "$HAS_MATCH"
rm -rf "$DIR"

# Case 8: empty bus (first-ever session, LAST_SESSION_TS=null path).
DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"
: > "$BUS"
RESULT=$(scan_for_self "$BUS" "2026-05-02T07:00:00Z" "commands/tester.md")
HAS_MATCH=$([ -n "$RESULT" ] && echo "yes" || echo "no")
assert_eq "case-8-empty-bus-no-match" "no" "$HAS_MATCH"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "story-done-role-files-updated: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
