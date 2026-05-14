#!/usr/bin/env bash
# Story 026 — spurious-wake bug protocol regression test.
#
# Synthetic-fixture bash test mirroring tests/manager-pre-sleep-liveness.sh.
# Inline helpers mirror the role's "Spurious wake reporting" logic and M's
# bus-wake-bug aggregation/digest behavior.

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

# -----------------------------------------------------------------------------
# Helper: peer_handle_wake — mirrors role's spurious-wake-reporting logic.
# Args: <line-json> <cursor-position> <line-number> <role>
# Echoes one of: emit:stale-line / emit:wrong-addressee / no-emit
# -----------------------------------------------------------------------------

peer_handle_wake() {
  local line_json="$1" cursor_pos="$2" line_no="$3" role="$4"
  local agent_id="${role}-test-001"
  local role_glob="${role}-*"
  # Stale-line check: did this line number get processed already?
  if [ "$line_no" -le "$cursor_pos" ]; then
    echo "emit:stale-line"
    return
  fi
  # Wrong-addressee check: is the line's `to` field NOT addressed to me?
  local to
  to=$(printf '%s' "$line_json" | jq -r '.to // empty')
  case "$to" in
    "*"|"$agent_id"|"$role_glob") echo "no-emit"; return ;;
    *) echo "emit:wrong-addressee"; return ;;
  esac
}

# Helper: should_fire_digest — mirrors M's digest threshold logic.
# Args: <count> <last-digest-ts-ISO-or-null> <now-ISO>
# Echoes: yes / no
should_fire_digest() {
  local count="$1" last_ts="$2" now_iso="$3"
  if [ "$count" -ge 10 ]; then
    echo "yes"
    return
  fi
  if [ "$last_ts" = "null" ] || [ -z "$last_ts" ]; then
    if [ "$count" -ge 1 ]; then
      # No prior digest; fire if any reports exist (initial daily mode).
      echo "yes"
      return
    fi
    echo "no"
    return
  fi
  # Compute age in seconds; >= 86400 (24h) → fire.
  local now_epoch last_epoch age
  now_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$now_iso" +%s 2>/dev/null || date -u -d "$now_iso" +%s)
  last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" +%s 2>/dev/null || date -u -d "$last_ts" +%s)
  age=$((now_epoch - last_epoch))
  if [ "$age" -ge 86400 ]; then
    echo "yes"
  else
    echo "no"
  fi
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: stale-line wake → emit bus-wake-bug.
RESULT=$(peer_handle_wake '{"to":"senior-developer-*","ts":"t","from":"x","type":"y"}' 10 5 "senior-developer")
assert_eq "case-1-stale-line-emit" "emit:stale-line" "$RESULT"

# Case 2: wrong-addressee wake → emit bus-wake-bug.
RESULT=$(peer_handle_wake '{"to":"tester-*","ts":"t","from":"x","type":"y"}' 5 6 "senior-developer")
assert_eq "case-2-wrong-addressee-emit" "emit:wrong-addressee" "$RESULT"

# Case 3: legitimate wake (cursor < line, role-glob match) → no emit.
RESULT=$(peer_handle_wake '{"to":"senior-developer-*","ts":"t","from":"x","type":"y"}' 5 6 "senior-developer")
assert_eq "case-3-legitimate-no-emit" "no-emit" "$RESULT"

# Case 4: M tracker increment — manager fixture has bus_wake_bugs:[].
DIR=$(mktemp -d)
echo '{"bus_wake_bugs":[],"last_bus_wake_bug_digest_ts":null}' > "$DIR/tracker.json"
# Simulate one bug-wake report arriving.
jq '.bus_wake_bugs += [{"reason":"stale-line","role":"senior-developer","timestamp":"2026-05-02T10:00:00Z"}]' "$DIR/tracker.json" > "$DIR/tracker.tmp" && mv "$DIR/tracker.tmp" "$DIR/tracker.json"
COUNT=$(jq '.bus_wake_bugs | length' "$DIR/tracker.json")
assert_eq "case-4-tracker-incremented" "1" "$COUNT"
rm -rf "$DIR"

# Case 5: digest fires at 10 reports.
RESULT=$(should_fire_digest 10 "null" "2026-05-02T10:00:00Z")
assert_eq "case-5-digest-fires-at-10" "yes" "$RESULT"

# Case 6: digest doesn't fire below threshold AND within 24h.
RESULT=$(should_fire_digest 5 "2026-05-02T08:00:00Z" "2026-05-02T10:00:00Z")
assert_eq "case-6-no-fire-below-threshold-recent" "no" "$RESULT"

# Case 7: daily digest fires (count below but >24h).
RESULT=$(should_fire_digest 3 "2026-05-01T08:00:00Z" "2026-05-02T10:00:00Z")
assert_eq "case-7-daily-fires" "yes" "$RESULT"

# Case 8: dismiss flushes counter.
DIR=$(mktemp -d)
echo '{"bus_wake_bugs":[{"reason":"stale-line"}],"last_bus_wake_bug_digest_ts":null}' > "$DIR/tracker.json"
jq --arg ts "2026-05-02T10:00:00Z" '.bus_wake_bugs = [] | .last_bus_wake_bug_digest_ts = $ts' "$DIR/tracker.json" > "$DIR/tracker.tmp" && mv "$DIR/tracker.tmp" "$DIR/tracker.json"
COUNT=$(jq '.bus_wake_bugs | length' "$DIR/tracker.json")
assert_eq "case-8-dismiss-flushes" "0" "$COUNT"
LAST=$(jq -r '.last_bus_wake_bug_digest_ts' "$DIR/tracker.json")
assert_eq "case-8-digest-ts-recorded" "2026-05-02T10:00:00Z" "$LAST"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Sprint-mode threshold cases (Story 028, introduced in v`<NEXT-to>`).
# Helper mirrors M's threshold logic with sprint_id awareness:
# - sprint_id non-empty → 5 reports OR 6h
# - sprint_id empty/null → 10 reports OR 24h
# -----------------------------------------------------------------------------

should_fire_digest_sprint_aware() {
  local count="$1" last_ts="$2" now_iso="$3" sprint_id="${4:-}"
  local threshold_count threshold_seconds
  if [ -n "$sprint_id" ] && [ "$sprint_id" != "null" ]; then
    threshold_count=5
    threshold_seconds=21600   # 6h
  else
    threshold_count=10
    threshold_seconds=86400   # 24h
  fi
  if [ "$count" -ge "$threshold_count" ]; then
    echo "yes"; return
  fi
  if [ "$last_ts" = "null" ] || [ -z "$last_ts" ]; then
    if [ "$count" -ge 1 ]; then echo "yes"; else echo "no"; fi
    return
  fi
  local now_epoch last_epoch age
  now_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$now_iso" +%s 2>/dev/null || date -u -d "$now_iso" +%s)
  last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" +%s 2>/dev/null || date -u -d "$last_ts" +%s)
  age=$((now_epoch - last_epoch))
  if [ "$age" -ge "$threshold_seconds" ]; then echo "yes"; else echo "no"; fi
}

# Case A: sprint mode, 5 reports → fire.
RESULT=$(should_fire_digest_sprint_aware 5 "2026-05-02T08:00:00Z" "2026-05-02T10:00:00Z" "2026-05-02-some-sprint")
assert_eq "case-A-sprint-5-fires" "yes" "$RESULT"

# Case B: sprint mode, 4 reports + recent digest → no fire.
RESULT=$(should_fire_digest_sprint_aware 4 "2026-05-02T09:30:00Z" "2026-05-02T10:00:00Z" "2026-05-02-some-sprint")
assert_eq "case-B-sprint-4-no-fire" "no" "$RESULT"

# Case C: steady-state, 5 reports + recent digest → no fire (threshold is 10).
RESULT=$(should_fire_digest_sprint_aware 5 "2026-05-02T08:00:00Z" "2026-05-02T10:00:00Z" "")
assert_eq "case-C-steady-5-no-fire" "no" "$RESULT"

# Case D: steady-state, 10 reports → fire.
RESULT=$(should_fire_digest_sprint_aware 10 "2026-05-02T08:00:00Z" "2026-05-02T10:00:00Z" "")
assert_eq "case-D-steady-10-fires" "yes" "$RESULT"

# Case E: sprint mode, 1 report + 6.5h since last digest → fire (time threshold).
RESULT=$(should_fire_digest_sprint_aware 1 "2026-05-02T03:30:00Z" "2026-05-02T10:00:00Z" "2026-05-02-some-sprint")
assert_eq "case-E-sprint-time-fires" "yes" "$RESULT"

# Case F: steady-state, 1 report + 7h since last digest → no fire (24h not yet).
RESULT=$(should_fire_digest_sprint_aware 1 "2026-05-02T03:00:00Z" "2026-05-02T10:00:00Z" "")
assert_eq "case-F-steady-time-no-fire" "no" "$RESULT"

# Boundary check G: sprint mode at exactly 6h0m0s elapsed → fire (>=).
RESULT=$(should_fire_digest_sprint_aware 1 "2026-05-02T04:00:00Z" "2026-05-02T10:00:00Z" "2026-05-02-some-sprint")
assert_eq "case-G-sprint-time-boundary-fires" "yes" "$RESULT"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "bus-wake-bug-protocol: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
