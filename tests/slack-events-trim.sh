#!/usr/bin/env bash
# Story 037 — opportunistic events.jsonl 1-week truncation test.
#
# Asserts the trim_events_feed helper's behavior on synthetic fixtures.
# Inline bash mirror of the helper from commands/slacker.md so the test is
# independent of the role file's path.
#
# Cases:
# 1. above-threshold mixed timestamps → trims to recent only
# 2. below-threshold no-op → file untouched
# 3. missing events.jsonl → no error, no-op
# 4. custom threshold via config file → trims when above custom threshold
# 5. malformed line (no ts field) → dropped per jq select semantics
# 6. idempotent — re-run is a no-op when already trimmed

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

# Inline trim_events_feed — mirror of commands/slacker.md "Events-feed trim helper".
# ROOT is set per-case to the fixture dir.
trim_events_feed() {
  local events="${ROOT}/implementations/.slack/events.jsonl"
  local threshold_file="${ROOT}/implementations/.slack/events-trim-threshold"
  local threshold=2000
  [ -f "$threshold_file" ] && threshold=$(cat "$threshold_file" | tr -d ' \n')
  [ -f "$events" ] || return 0
  local lines; lines=$(wc -l < "$events" 2>/dev/null | tr -d ' '); lines=${lines:-0}
  [ "$lines" -ge "$threshold" ] || return 0
  local cutoff
  cutoff=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  jq -c --arg cutoff "$cutoff" 'select(.ts >= $cutoff)' "$events" > "$events.tmp" \
    && mv "$events.tmp" "$events"
}

# Fixture builder: creates events.jsonl with `recent_count` lines dated now,
# and `old_count` lines dated 14 days ago.
mk_events_fixture() {
  local fix="$1" recent_count="$2" old_count="$3"
  mkdir -p "$fix/implementations/.slack"
  local events="$fix/implementations/.slack/events.jsonl"
  : > "$events"
  local now_ts; now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local old_ts; old_ts=$(date -u -v-14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                       || date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)
  local i=0
  while [ $i -lt "$old_count" ]; do
    printf '{"ts":"%s","type":"message","payload":"old-%d"}\n' "$old_ts" "$i" >> "$events"
    i=$((i+1))
  done
  i=0
  while [ $i -lt "$recent_count" ]; do
    printf '{"ts":"%s","type":"message","payload":"recent-%d"}\n' "$now_ts" "$i" >> "$events"
    i=$((i+1))
  done
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: above-threshold mixed → trims to recent only.
ROOT=$(mktemp -d)
mk_events_fixture "$ROOT" 1500 1500   # 3000 lines total, threshold 2000
BEFORE=$(wc -l < "$ROOT/implementations/.slack/events.jsonl" | tr -d ' ')
trim_events_feed
AFTER=$(wc -l < "$ROOT/implementations/.slack/events.jsonl" | tr -d ' ')
assert_eq "case-1-before-count" "3000" "$BEFORE"
assert_eq "case-1-after-count" "1500" "$AFTER"
OLD_REMAINING=$(grep -c '"old-' "$ROOT/implementations/.slack/events.jsonl" || true)
assert_eq "case-1-no-old-remains" "0" "$OLD_REMAINING"
RECENT_REMAINING=$(grep -c '"recent-' "$ROOT/implementations/.slack/events.jsonl" || true)
assert_eq "case-1-recent-preserved" "1500" "$RECENT_REMAINING"
rm -rf "$ROOT"

# Case 2: below-threshold no-op.
ROOT=$(mktemp -d)
mk_events_fixture "$ROOT" 500 500    # 1000 lines, threshold 2000 → no-op
EVENTS="$ROOT/implementations/.slack/events.jsonl"
BEFORE_SHA=$(shasum -a 1 "$EVENTS" | awk '{print $1}')
trim_events_feed
AFTER_SHA=$(shasum -a 1 "$EVENTS" | awk '{print $1}')
LINES_AFTER=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case-2-below-threshold-noop-sha" "$BEFORE_SHA" "$AFTER_SHA"
assert_eq "case-2-below-threshold-noop-lines" "1000" "$LINES_AFTER"
rm -rf "$ROOT"

# Case 3: missing events.jsonl → no error, no-op.
ROOT=$(mktemp -d)
mkdir -p "$ROOT/implementations/.slack"   # dir exists but no events.jsonl
trim_events_feed
RC=$?
assert_eq "case-3-missing-file-rc" "0" "$RC"
EXISTS=$([ -f "$ROOT/implementations/.slack/events.jsonl" ] && echo "yes" || echo "no")
assert_eq "case-3-missing-file-still-missing" "no" "$EXISTS"
rm -rf "$ROOT"

# Case 4: custom threshold via config file.
ROOT=$(mktemp -d)
mk_events_fixture "$ROOT" 600 600    # 1200 lines
echo "1000" > "$ROOT/implementations/.slack/events-trim-threshold"
trim_events_feed
LINES_AFTER=$(wc -l < "$ROOT/implementations/.slack/events.jsonl" | tr -d ' ')
assert_eq "case-4-custom-threshold-trimmed" "600" "$LINES_AFTER"
rm -rf "$ROOT"

# Case 5: malformed line (no ts field) is dropped by jq select.
ROOT=$(mktemp -d)
mkdir -p "$ROOT/implementations/.slack"
EVENTS="$ROOT/implementations/.slack/events.jsonl"
NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# 2100 lines: 100 recent (with ts) + 100 malformed (no ts) + 1900 recent
i=0; while [ $i -lt 100 ]; do printf '{"ts":"%s","type":"good","i":%d}\n' "$NOW_TS" "$i" >> "$EVENTS"; i=$((i+1)); done
i=0; while [ $i -lt 100 ]; do printf '{"type":"malformed","i":%d}\n' "$i" >> "$EVENTS"; i=$((i+1)); done
i=0; while [ $i -lt 1900 ]; do printf '{"ts":"%s","type":"good","i":%d}\n' "$NOW_TS" "$i" >> "$EVENTS"; i=$((i+1)); done
BEFORE=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case-5-before-count" "2100" "$BEFORE"
trim_events_feed
AFTER=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case-5-malformed-dropped" "2000" "$AFTER"
MALFORMED_REMAINING=$(grep -c '"malformed"' "$EVENTS" || true)
assert_eq "case-5-no-malformed-remains" "0" "$MALFORMED_REMAINING"
rm -rf "$ROOT"

# Case 6: idempotent.
ROOT=$(mktemp -d)
mk_events_fixture "$ROOT" 1500 1500   # 3000 lines, threshold 2000
trim_events_feed                       # 1st pass: trims to 1500
LINES_1=$(wc -l < "$ROOT/implementations/.slack/events.jsonl" | tr -d ' ')
trim_events_feed                       # 2nd pass: below threshold, no-op
LINES_2=$(wc -l < "$ROOT/implementations/.slack/events.jsonl" | tr -d ' ')
assert_eq "case-6-after-1st-pass" "1500" "$LINES_1"
assert_eq "case-6-after-2nd-pass-noop" "1500" "$LINES_2"
rm -rf "$ROOT"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "slack-events-trim: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
