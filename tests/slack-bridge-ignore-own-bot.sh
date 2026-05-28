#!/usr/bin/env bash
# Story 153 — Slack bridge own-bot filter behavior + auth.test failure routing.
#
# Synthetic-fixture bash test mirroring tests/slack-bridge-spawn.sh and
# slacker-bridge-launch.sh patterns. Helpers mirror the bridge's
# eventIsFromOwnBot predicate at the bash level + S's matched-fail-closed
# parse path.
#
# Production TypeScript logic in plugin/bridge/slack/src/bridge/bot-identity.ts
# is exercised separately by plugin/bridge/slack/tests/own-bot-filter.test.ts
# (node:test, run via `cd plugin/bridge/slack && npm test`).

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

assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

# -----------------------------------------------------------------------------
# Helpers — mirror the bridge's eventIsFromOwnBot predicate in bash.
# -----------------------------------------------------------------------------

# event_is_from_own_bot <event-json> <our-user-id> <our-bot-id>
#   Echoes "yes" or "no". Mirrors the 4-predicate truth table in
#   bot-identity.ts:eventIsFromOwnBot. Uses jq to inspect event fields.
event_is_from_own_bot() {
  local ev="$1" uid="$2" bid="$3"
  # Predicate 1: event.user === userId
  if [ "$(printf '%s' "$ev" | jq -r '.user // empty')" = "$uid" ]; then
    echo yes; return
  fi
  # Predicate 2: subtype=bot_message + bot_id matches
  local subtype evbid
  subtype=$(printf '%s' "$ev" | jq -r '.subtype // empty')
  evbid=$(printf '%s' "$ev" | jq -r '.bot_id // empty')
  if [ "$subtype" = "bot_message" ] && [ -n "$bid" ] && [ "$evbid" = "$bid" ]; then
    echo yes; return
  fi
  # Predicate 3: message_changed where event.message.user is us
  if [ "$subtype" = "message_changed" ]; then
    local muser
    muser=$(printf '%s' "$ev" | jq -r '.message.user // empty')
    if [ "$muser" = "$uid" ]; then
      echo yes; return
    fi
  fi
  # Predicate 4: message_deleted where event.previous_message.user is us
  if [ "$subtype" = "message_deleted" ]; then
    local puser
    puser=$(printf '%s' "$ev" | jq -r '.previous_message.user // empty')
    if [ "$puser" = "$uid" ]; then
      echo yes; return
    fi
  fi
  echo no
}

# parse_fail_closed_prefix <stdout-line>
#   Returns the cause-detail substring matching the three fail-closed-exit
#   prefixes (workspace mismatch / missing OAuth scope(s) / auth.test failed).
#   Returns empty if no match — mirrors slacker.md line 152's behavior.
parse_fail_closed_prefix() {
  local line="$1"
  case "$line" in
    "[claude-slack-bridge] workspace mismatch:"*" — exiting")
      printf '%s' "$line" | sed -E 's|^\[claude-slack-bridge\] (.*) — exiting$|\1|'
      ;;
    "[claude-slack-bridge] missing OAuth scope(s):"*" — exiting")
      printf '%s' "$line" | sed -E 's|^\[claude-slack-bridge\] (.*) — exiting$|\1|'
      ;;
    "[claude-slack-bridge] auth.test failed:"*" — exiting")
      printf '%s' "$line" | sed -E 's|^\[claude-slack-bridge\] (.*) — exiting$|\1|'
      ;;
    *)
      printf ''
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------
OUR_UID="U_OWN_BOT"
OUR_BID="B_OWN_BOT"
OTHER_UID="U_SOMEONE"

# ── Case 1: inbound message from another user → not from own bot
EV='{"user":"'"$OTHER_UID"'","text":"hi"}'
assert_eq "case1: message from another user → forwarded" "no" "$(event_is_from_own_bot "$EV" "$OUR_UID" "$OUR_BID")"

# ── Case 2: inbound message from our bot → from own bot (dropped)
EV='{"user":"'"$OUR_UID"'","text":"my reply"}'
assert_eq "case2: message from our bot → dropped" "yes" "$(event_is_from_own_bot "$EV" "$OUR_UID" "$OUR_BID")"

# ── Case 3: inbound message_changed for our bot's authored message → dropped
EV='{"subtype":"message_changed","message":{"user":"'"$OUR_UID"'","text":"edit"}}'
assert_eq "case3: message_changed (own-bot author) → dropped" "yes" "$(event_is_from_own_bot "$EV" "$OUR_UID" "$OUR_BID")"

# ── Case 4: inbound reaction_added from our bot → dropped
EV='{"user":"'"$OUR_UID"'","reaction":"thumbsup"}'
assert_eq "case4: reaction from our bot → dropped" "yes" "$(event_is_from_own_bot "$EV" "$OUR_UID" "$OUR_BID")"

# ── Case 5: inbound reaction_added from another user on our bot's message → forwarded
EV='{"user":"'"$OTHER_UID"'","reaction":"thumbsup","item":{"channel":"C1","ts":"123.4"}}'
assert_eq "case5: another user's reaction on our message → forwarded" "no" "$(event_is_from_own_bot "$EV" "$OUR_UID" "$OUR_BID")"

# ── Case 6a: auth.test failure stdout line is parsed by S's matched-fail-closed predicate
LINE='[claude-slack-bridge] auth.test failed: missing_scope — exiting'
PARSED=$(parse_fail_closed_prefix "$LINE")
assert_eq "case6a: auth.test failed stdout matches fail-closed-exit pattern" "auth.test failed: missing_scope" "$PARSED"

# ── Case 6b: workspace-mismatch line still parses (regression guard)
LINE='[claude-slack-bridge] workspace mismatch: expected TX, got team=ty id=TY — exiting'
PARSED=$(parse_fail_closed_prefix "$LINE")
assert_contains "case6b: workspace-mismatch still parses" "workspace mismatch:" "$PARSED"

# ── Case 6c: missing-scope line still parses (regression guard)
LINE='[claude-slack-bridge] missing OAuth scope(s): chat:write — exiting'
PARSED=$(parse_fail_closed_prefix "$LINE")
assert_contains "case6c: missing-scope still parses" "missing OAuth scope(s):" "$PARSED"

# ── Case 6d: an unrelated stdout line is NOT matched
LINE='[claude-slack-bridge] bot user id: U_X'
PARSED=$(parse_fail_closed_prefix "$LINE")
assert_eq "case6d: unrelated stdout line not matched" "" "$PARSED"

# ── Case 7: bot_message subtype with matching bot_id → dropped
EV='{"subtype":"bot_message","bot_id":"'"$OUR_BID"'","bot_profile":{"app_id":"A1"}}'
assert_eq "case7: bot_message with matching bot_id → dropped" "yes" "$(event_is_from_own_bot "$EV" "$OUR_UID" "$OUR_BID")"

# ── Case 8: bot_message subtype with different bot_id → forwarded
EV='{"subtype":"bot_message","bot_id":"B_OTHER_BOT"}'
assert_eq "case8: bot_message from another bot → forwarded" "no" "$(event_is_from_own_bot "$EV" "$OUR_UID" "$OUR_BID")"

# ── Case 9: slacker.md line 152 lists 'auth.test failed:' alongside the existing 2 prefixes
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SLACKER_MD="$ROOT/commands/slacker.md"
GREP_OUT=$(grep -c "auth.test failed:" "$SLACKER_MD" 2>/dev/null || true)
if [ "$GREP_OUT" -ge 1 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case9: slacker.md missing 'auth.test failed:' prefix")
fi

# ── Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
