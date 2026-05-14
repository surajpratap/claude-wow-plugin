#!/usr/bin/env bash
# Story 025 — /afk + Leader-AFK protocol regression test.
#
# Synthetic-fixture bash test mirroring tests/manager-pre-sleep-liveness.sh.
# Inline afk_decide(fixture, command) helper mirrors M's prompt logic from
# spec Section A (/afk) and Section F (/back).

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
# Inline helper — mirrors M's /afk + /back logic.
# Args: <fixture-dir> <command: /afk | /back | <user-prompt-submit-hook> | leader-decision-request:<allowed|catastrophic>>
# Echoes one of:
#   acked:idle / acked:leader / no-op / back-acked / no-op-back / decided:audited / decided:escalated
# Side-effects: updates tracker.json + emits to bus.jsonl + creates/updates audit-log mirror.
# -----------------------------------------------------------------------------

afk_decide() {
  local dir="$1" cmd="$2"
  local tracker="$dir/tracker.json"
  local bus="$dir/bus.jsonl"
  local now="2026-05-02T10:00:00Z"

  local active mode session_id
  active=$(jq -r '.afk_active // false' "$tracker")
  mode=$(jq -r '.afk_mode // ""' "$tracker")
  session_id=$(jq -r '.last_afk_session_id // ""' "$tracker")

  case "$cmd" in
    /afk)
      if [ "$active" = "true" ]; then
        echo "no-op"
        return
      fi
      # Branch on team state — fixture has manifest.json with in_flight count.
      local in_flight
      in_flight=$(jq '.in_flight // 0' "$dir/manifest.json" 2>/dev/null || echo 0)
      local new_mode
      if [ "$in_flight" -eq 0 ]; then
        new_mode="idle"
      else
        new_mode="leader"
      fi
      local new_id="20260502T100000-aaaaaa"
      jq --arg m "$new_mode" --arg ts "$now" --arg id "$new_id" \
        '.afk_active = true | .afk_mode = $m | .afk_started_ts = $ts | .last_afk_session_id = $id | .leader_decisions = []' \
        "$tracker" > "$tracker.tmp" && mv "$tracker.tmp" "$tracker"
      mkdir -p "$dir/.afk"
      printf '<!-- afk-session: %s -->\n<!-- mode: %s -->\n<!-- started_ts: %s -->\n' \
        "$new_id" "$new_mode" "$now" > "$dir/.afk/$new_id-decisions.md"
      printf '{"ts":"%s","from":"manager-test","to":"*","type":"human-afk","payload":{"mode":"%s"}}\n' \
        "$now" "$new_mode" >> "$bus"
      echo "acked:$new_mode"
      ;;
    /back)
      if [ "$active" != "true" ]; then
        echo "no-op-back"
        return
      fi
      local prev_mode="$mode"
      jq --arg ts "$now" --arg m "$prev_mode" \
        '.afk_active = false | .afk_mode = null | .afk_started_ts = null' \
        "$tracker" > "$tracker.tmp" && mv "$tracker.tmp" "$tracker"
      printf '%s\n' "<!-- /afk-session @ $now -->" >> "$dir/.afk/$session_id-decisions.md"
      printf '{"ts":"%s","from":"manager-test","to":"*","type":"human-back","payload":{"previous_mode":"%s"}}\n' \
        "$now" "$prev_mode" >> "$bus"
      echo "back-acked"
      ;;
    user-prompt-submit-hook)
      # Implicit return on user-prompt-submit-hook event (per Section G).
      if [ "$active" = "true" ]; then
        afk_decide "$dir" "/back"
      else
        echo "no-op-back"
      fi
      ;;
    leader-decision-request:allowed)
      if [ "$active" != "true" ] || [ "$mode" != "leader" ]; then
        echo "decided:escalated"
        return
      fi
      # Append to leader_decisions
      jq --arg ts "$now" \
        '.leader_decisions += [{"ts":$ts, "decision":"test allowed", "reasoning":"test", "scope":"scope-clarification"}]' \
        "$tracker" > "$tracker.tmp" && mv "$tracker.tmp" "$tracker"
      printf '{"ts":"%s","from":"manager-test","to":"*","type":"leader-decision","payload":{"decision":"test allowed"}}\n' \
        "$now" >> "$bus"
      echo "decided:audited"
      ;;
    leader-decision-request:catastrophic)
      # Catastrophic class — always escalate, never auto-decide.
      echo "decided:escalated"
      ;;
    *)
      echo "unknown-cmd"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Fixture builder
# -----------------------------------------------------------------------------

mk_fixture() {
  local in_flight="${1:-0}"
  local dir; dir=$(mktemp -d)
  echo "{\"in_flight\":$in_flight}" > "$dir/manifest.json"
  echo '{"afk_active":false,"afk_mode":null,"afk_started_ts":null,"leader_decisions":[],"last_afk_session_id":null}' > "$dir/tracker.json"
  : > "$dir/bus.jsonl"
  echo "$dir"
}

# -----------------------------------------------------------------------------
# Cases (8 per spec Section L AC #10)
# -----------------------------------------------------------------------------

# Case 1: idle-AFK trigger (nothing in flight).
DIR=$(mk_fixture 0)
RESULT=$(afk_decide "$DIR" "/afk")
assert_eq "case-1-idle-trigger-acked" "acked:idle" "$RESULT"
TRACKER_MODE=$(jq -r '.afk_mode' "$DIR/tracker.json")
assert_eq "case-1-tracker-mode-idle" "idle" "$TRACKER_MODE"
LAST_BUS=$(tail -1 "$DIR/bus.jsonl")
case "$LAST_BUS" in *'"mode":"idle"'*) assert_eq "case-1-bus-emit-idle" "yes" "yes";; *) assert_eq "case-1-bus-emit-idle" "yes" "no";; esac
rm -rf "$DIR"

# Case 2: Leader-AFK trigger (in flight).
DIR=$(mk_fixture 2)
RESULT=$(afk_decide "$DIR" "/afk")
assert_eq "case-2-leader-trigger-acked" "acked:leader" "$RESULT"
TRACKER_MODE=$(jq -r '.afk_mode' "$DIR/tracker.json")
assert_eq "case-2-tracker-mode-leader" "leader" "$TRACKER_MODE"
LAST_BUS=$(tail -1 "$DIR/bus.jsonl")
case "$LAST_BUS" in *'"mode":"leader"'*) assert_eq "case-2-bus-emit-leader" "yes" "yes";; *) assert_eq "case-2-bus-emit-leader" "yes" "no";; esac
rm -rf "$DIR"

# Case 3: /back digest — afk_active true → close + emit + reset.
DIR=$(mk_fixture 2)
afk_decide "$DIR" "/afk" > /dev/null
afk_decide "$DIR" "leader-decision-request:allowed" > /dev/null
afk_decide "$DIR" "leader-decision-request:allowed" > /dev/null
RESULT=$(afk_decide "$DIR" "/back")
assert_eq "case-3-back-acked" "back-acked" "$RESULT"
TRACKER_ACTIVE=$(jq -r '.afk_active' "$DIR/tracker.json")
assert_eq "case-3-tracker-not-active" "false" "$TRACKER_ACTIVE"
DECISIONS_COUNT=$(jq '.leader_decisions | length' "$DIR/tracker.json")
assert_eq "case-3-decisions-recorded" "2" "$DECISIONS_COUNT"
rm -rf "$DIR"

# Case 4: implicit /back via user-prompt-submit-hook.
DIR=$(mk_fixture 1)
afk_decide "$DIR" "/afk" > /dev/null
RESULT=$(afk_decide "$DIR" "user-prompt-submit-hook")
assert_eq "case-4-implicit-back" "back-acked" "$RESULT"
rm -rf "$DIR"

# Case 5: multi-AFK no-op.
DIR=$(mk_fixture 0)
afk_decide "$DIR" "/afk" > /dev/null
RESULT=$(afk_decide "$DIR" "/afk")
assert_eq "case-5-multi-afk-noop" "no-op" "$RESULT"
rm -rf "$DIR"

# Case 6: /back without AFK no-op.
DIR=$(mk_fixture 0)
RESULT=$(afk_decide "$DIR" "/back")
assert_eq "case-6-back-without-afk-noop" "no-op-back" "$RESULT"
rm -rf "$DIR"

# Case 7: catastrophic-block escalates (does NOT auto-decide).
DIR=$(mk_fixture 1)
afk_decide "$DIR" "/afk" > /dev/null
RESULT=$(afk_decide "$DIR" "leader-decision-request:catastrophic")
assert_eq "case-7-catastrophic-escalates" "decided:escalated" "$RESULT"
DECISIONS_COUNT=$(jq '.leader_decisions | length' "$DIR/tracker.json")
assert_eq "case-7-no-audit-entry-on-escalate" "0" "$DECISIONS_COUNT"
rm -rf "$DIR"

# Case 8: allowed-decision audited.
DIR=$(mk_fixture 1)
afk_decide "$DIR" "/afk" > /dev/null
RESULT=$(afk_decide "$DIR" "leader-decision-request:allowed")
assert_eq "case-8-allowed-audited" "decided:audited" "$RESULT"
DECISIONS_COUNT=$(jq '.leader_decisions | length' "$DIR/tracker.json")
assert_eq "case-8-audit-entry-recorded" "1" "$DECISIONS_COUNT"
LAST_BUS=$(tail -1 "$DIR/bus.jsonl")
case "$LAST_BUS" in *'"type":"leader-decision"'*) assert_eq "case-8-leader-decision-emitted" "yes" "yes";; *) assert_eq "case-8-leader-decision-emitted" "yes" "no";; esac
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "manager-afk-mode: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
