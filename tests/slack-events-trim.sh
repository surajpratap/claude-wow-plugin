#!/usr/bin/env bash
# Story 037 / 094 — opportunistic events.jsonl 1-week truncation test.
#
# Exercises the real plugin/scripts/slack-events-trim.sh (Story 094 extracted it from
# the trim_events_feed doctrine helper). The feed's `ts` is the raw Slack message
# timestamp — a Unix-epoch decimal string (also the message identifier); the trim's
# cutoff is a matching Unix epoch and the jq comparison is numeric. Fixtures emit
# Unix-epoch `ts` (the old ISO-8601 fixtures masked the ts/cutoff mismatch — backlog 133).
#
# Cases:
# 1. above-threshold mixed timestamps → trims to recent only (the 1-week window)
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

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/slack-events-trim.sh"
[ -f "$SCRIPT" ] || { echo "slack-events-trim: script not found: $SCRIPT" >&2; exit 1; }

# now / 14-days-ago as Unix epochs (BSD `date` || GNU `date`).
NOW=$(date -u +%s)
OLD=$(date -u -v-14d +%s 2>/dev/null || date -u -d '14 days ago' +%s)

# Fixture builder: events.jsonl with `recent_count` lines dated now (a nonzero
# fractional ts — the real Slack shape) and `old_count` lines dated 14 days ago.
mk_events_fixture() {
  local fix="$1" recent_count="$2" old_count="$3"
  mkdir -p "$fix/implementations/.slack"
  local events="$fix/implementations/.slack/events.jsonl"
  : > "$events"
  local i=0
  while [ $i -lt "$old_count" ]; do
    printf '{"ts":"%s.000000","type":"message","payload":"old-%d"}\n' "$OLD" "$i" >> "$events"
    i=$((i+1))
  done
  i=0
  while [ $i -lt "$recent_count" ]; do
    printf '{"ts":"%s.002500","type":"message","payload":"recent-%d"}\n' "$NOW" "$i" >> "$events"
    i=$((i+1))
  done
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: above-threshold mixed → trims to the recent 1-week window only.
ROOT=$(mktemp -d)
mk_events_fixture "$ROOT" 1500 1500   # 3000 lines total, threshold 2000
EVENTS="$ROOT/implementations/.slack/events.jsonl"
BEFORE=$(wc -l < "$EVENTS" | tr -d ' ')
bash "$SCRIPT" "$EVENTS"
AFTER=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case-1-before-count" "3000" "$BEFORE"
assert_eq "case-1-after-count" "1500" "$AFTER"
OLD_REMAINING=$(grep -c '"old-' "$EVENTS" || true)
assert_eq "case-1-no-old-remains" "0" "$OLD_REMAINING"
RECENT_REMAINING=$(grep -c '"recent-' "$EVENTS" || true)
assert_eq "case-1-recent-preserved" "1500" "$RECENT_REMAINING"
rm -rf "$ROOT"

# Case 2: below-threshold no-op.
ROOT=$(mktemp -d)
mk_events_fixture "$ROOT" 500 500    # 1000 lines, threshold 2000 → no-op
EVENTS="$ROOT/implementations/.slack/events.jsonl"
BEFORE_SHA=$(shasum -a 1 "$EVENTS" | awk '{print $1}')
bash "$SCRIPT" "$EVENTS"
AFTER_SHA=$(shasum -a 1 "$EVENTS" | awk '{print $1}')
LINES_AFTER=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case-2-below-threshold-noop-sha" "$BEFORE_SHA" "$AFTER_SHA"
assert_eq "case-2-below-threshold-noop-lines" "1000" "$LINES_AFTER"
rm -rf "$ROOT"

# Case 3: missing events.jsonl → no error, no-op.
ROOT=$(mktemp -d)
mkdir -p "$ROOT/implementations/.slack"   # dir exists but no events.jsonl
bash "$SCRIPT" "$ROOT/implementations/.slack/events.jsonl"
RC=$?
assert_eq "case-3-missing-file-rc" "0" "$RC"
EXISTS=$([ -f "$ROOT/implementations/.slack/events.jsonl" ] && echo "yes" || echo "no")
assert_eq "case-3-missing-file-still-missing" "no" "$EXISTS"
rm -rf "$ROOT"

# Case 4: custom threshold via config file.
ROOT=$(mktemp -d)
mk_events_fixture "$ROOT" 600 600    # 1200 lines
echo "1000" > "$ROOT/implementations/.slack/events-trim-threshold"
bash "$SCRIPT" "$ROOT/implementations/.slack/events.jsonl"
LINES_AFTER=$(wc -l < "$ROOT/implementations/.slack/events.jsonl" | tr -d ' ')
assert_eq "case-4-custom-threshold-trimmed" "600" "$LINES_AFTER"
rm -rf "$ROOT"

# Case 5: malformed line (no ts field) is dropped by jq select.
ROOT=$(mktemp -d)
mkdir -p "$ROOT/implementations/.slack"
EVENTS="$ROOT/implementations/.slack/events.jsonl"
# 2100 lines: 100 recent (with ts) + 100 malformed (no ts) + 1900 recent
i=0; while [ $i -lt 100 ]; do printf '{"ts":"%s.002500","type":"good","i":%d}\n' "$NOW" "$i" >> "$EVENTS"; i=$((i+1)); done
i=0; while [ $i -lt 100 ]; do printf '{"type":"malformed","i":%d}\n' "$i" >> "$EVENTS"; i=$((i+1)); done
i=0; while [ $i -lt 1900 ]; do printf '{"ts":"%s.002500","type":"good","i":%d}\n' "$NOW" "$i" >> "$EVENTS"; i=$((i+1)); done
BEFORE=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case-5-before-count" "2100" "$BEFORE"
bash "$SCRIPT" "$EVENTS"
AFTER=$(wc -l < "$EVENTS" | tr -d ' ')
assert_eq "case-5-malformed-dropped" "2000" "$AFTER"
MALFORMED_REMAINING=$(grep -c '"malformed"' "$EVENTS" || true)
assert_eq "case-5-no-malformed-remains" "0" "$MALFORMED_REMAINING"
rm -rf "$ROOT"

# Case 6: idempotent.
ROOT=$(mktemp -d)
mk_events_fixture "$ROOT" 1500 1500   # 3000 lines, threshold 2000
EVENTS="$ROOT/implementations/.slack/events.jsonl"
bash "$SCRIPT" "$EVENTS"               # 1st pass: trims to 1500
LINES_1=$(wc -l < "$EVENTS" | tr -d ' ')
bash "$SCRIPT" "$EVENTS"               # 2nd pass: below threshold, no-op
LINES_2=$(wc -l < "$EVENTS" | tr -d ' ')
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
