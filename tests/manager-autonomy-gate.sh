#!/usr/bin/env bash
# Story 014 / Section G — autonomy-gate regression test.
#
# Synthetic-fixture bash test. Each case sets up a temp implementations/
# tree (backlog files + story files + .agents/<id>.json tracker), runs
# the inline gate-decision helper (which mirrors M's prompt logic), and
# asserts the decision (item id selected OR "none") + the brake side-
# effects (cooldown markers, tracker pause field).
#
# The helper IS the spec for what the gate computes. If M's prompt
# diverges from the helper, this test fails — and the prompt edit
# should land in the same commit as the helper update.

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
  local name="$1"; local needle="$2"; local haystack="$3"
  if printf '%s' "$haystack" | grep -q -F -- "$needle"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected to contain '$needle')")
  fi
}

# -----------------------------------------------------------------------
# gate_decision <fixture-dir>
#   Reads the fixture and prints the selected item id (or "none").
#   Mirrors the 5-condition gate + tie-breakers from manager.md
#   "Cron lifecycle → Autonomous pickup".
# -----------------------------------------------------------------------
gate_decision() {
  local fix="$1"
  local tracker="$fix/implementations/.agents/m.json"
  local now_ts
  now_ts=$(date -u +%s)

  # Condition 1: AFK signal — last_user_prompt_ts ≥ 60min ago, OR
  # afk_phrase_present == "1" in the tracker.
  local last_prompt_ts afk_phrase
  last_prompt_ts=$(jq -r '.last_user_prompt_ts // ""' "$tracker")
  afk_phrase=$(jq -r '.afk_phrase_present // ""' "$tracker")
  local afk_ok=0
  if [ "$afk_phrase" = "1" ]; then
    afk_ok=1
  elif [ -n "$last_prompt_ts" ] && [ "$last_prompt_ts" != "null" ]; then
    local last_epoch
    last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last_prompt_ts" +%s 2>/dev/null \
      || date -u -d "$last_prompt_ts" +%s 2>/dev/null)
    if [ -n "$last_epoch" ] && [ "$((now_ts - last_epoch))" -ge 3600 ]; then
      afk_ok=1
    fi
  else
    # null last_prompt_ts means we've never seen one — qualifies as AFK
    afk_ok=1
  fi
  [ "$afk_ok" -eq 1 ] || { echo "none"; return; }

  # Condition 2: Team idle — peers_alive == "1" AND no in-progress/in-review story.
  local peers_alive
  peers_alive=$(jq -r '.peers_alive // ""' "$tracker")
  [ "$peers_alive" = "1" ] || { echo "none"; return; }
  local in_flight
  in_flight=$(grep -lE '^<!-- status: in-(progress|review) -->' "$fix/implementations/stories/"*.md 2>/dev/null | head -1 || true)
  [ -z "$in_flight" ] || { echo "none"; return; }

  # Condition 4: No in-flight auto-promotion — any story with auto-promoted-by-m + status not done/cancelled/rejected.
  local in_flight_auto=""
  for f in $(grep -lE 'auto-promoted-by-m' "$fix/implementations/stories/"*.md 2>/dev/null); do
    local s; s=$(head -1 "$f")
    if printf '%s' "$s" | grep -qvE 'status: (done|cancelled|rejected)'; then
      in_flight_auto="$f"
      break
    fi
  done
  [ -z "$in_flight_auto" ] || { echo "none"; return; }

  # Condition 5: No active global pause.
  local paused_until
  paused_until=$(jq -r '.auto_promote_paused_until // ""' "$tracker")
  if [ -n "$paused_until" ] && [ "$paused_until" != "null" ]; then
    local pause_epoch
    pause_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$paused_until" +%s 2>/dev/null \
      || date -u -d "$paused_until" +%s 2>/dev/null)
    if [ -n "$pause_epoch" ] && [ "$pause_epoch" -gt "$now_ts" ]; then
      echo "none"; return
    fi
  fi

  # Condition 3: Eligibility — accepted AND (concern=hygiene AND size IN tiny/small)
  # Combined with Condition 5 per-item: no live auto-promote-cooldown.
  # Tie-breakers: FIFO by mtime → concern priority → size priority.
  local candidates=()
  for f in "$fix/implementations/backlog/"*.md; do
    [ -f "$f" ] || continue
    local status concern size cooldown
    status=$(grep -oE 'status: [a-z]+' "$f" | head -1 | awk '{print $2}')
    concern=$(grep -oE 'concern: [a-z]+' "$f" | head -1 | awk '{print $2}')
    size=$(grep -oE 'size: [a-z]+' "$f" | head -1 | awk '{print $2}')
    cooldown=$(grep -oE 'auto-promote-cooldown: until [^ ]+' "$f" | head -1 | awk '{print $3}')
    [ "$status" = "accepted" ] || continue
    [ "$concern" = "hygiene" ] || continue
    case "$size" in tiny|small) ;; *) continue ;; esac
    if [ -n "$cooldown" ]; then
      local cd_epoch
      cd_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$cooldown" +%s 2>/dev/null \
        || date -u -d "$cooldown" +%s 2>/dev/null)
      if [ -n "$cd_epoch" ] && [ "$cd_epoch" -gt "$now_ts" ]; then
        continue  # active cooldown, skip
      fi
    fi
    local id; id=$(basename "$f" | grep -oE '^[0-9]+')
    local mtime; mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
    # concern priority: hygiene=0, robustness=1, feature=2, architecture=3
    # size priority: tiny=0, small=1, medium=2, large=3
    local cp=0 sp=0
    case "$concern" in hygiene) cp=0;; robustness) cp=1;; feature) cp=2;; architecture) cp=3;; esac
    case "$size" in tiny) sp=0;; small) sp=1;; medium) sp=2;; large) sp=3;; esac
    candidates+=("$mtime $cp $sp $id $f")
  done
  [ "${#candidates[@]}" -gt 0 ] || { echo "none"; return; }

  # Sort: mtime ascending (oldest first), then concern priority asc, then size priority asc.
  local picked
  picked=$(printf '%s\n' "${candidates[@]}" | sort -k1,1n -k2,2n -k3,3n | head -1 | awk '{print $4}')
  echo "$picked"
}

# -----------------------------------------------------------------------
# gate_brake <fixture-dir> <source-backlog-basename>
#   Mirrors M's prompt logic for the disapproval brake (Story 014 Section D).
#   Side-effects (no stdout):
#     - Scans fixture bus for the most recent <user-prompt-submit-hook> line.
#     - Applies the 10-phrase substring matcher.
#     - Finds most recent auto-promoted-by-m story.
#     - On bind:
#         (a) appends `<!-- auto-promote-cooldown: until <NOW + 30d ISO> -->`
#             to the named source backlog file
#         (b) sets tracker `auto_promote_paused_until` to <NOW + 24h ISO>.
#     - Returns 0 on bind, 1 if no brake phrase matched, 2 if no auto-promoted
#       story found.
# -----------------------------------------------------------------------
gate_brake() {
  local fix="$1" source_basename="$2"
  local bus="$fix/implementations/.message-bus.jsonl"
  local tracker="$fix/implementations/.agents/m.json"
  local backlog_file="$fix/implementations/backlog/$source_basename"

  # Step 1: most recent user-prompt-submit-hook payload.
  local recent_msg
  recent_msg=$(grep -E '"<user-prompt-submit-hook>"|user-prompt-submit-hook' "$bus" 2>/dev/null \
    | tail -1 | jq -r '.payload // ""' 2>/dev/null)
  if [ -z "$recent_msg" ]; then
    return 1
  fi

  # Step 2: case-insensitive substring matcher (10 phrases per Story 014 Section D).
  local lower
  lower=$(printf '%s' "$recent_msg" | tr '[:upper:]' '[:lower:]')
  local matched=0
  for phrase in 'nope' 'undo' 'not that' 'cancel that' "no don't" 'revert' "i didn't want that" 'wrong one' 'take that back' 'roll that back'; do
    case "$lower" in *"$phrase"*) matched=1; break ;; esac
  done
  if [ "$matched" -eq 0 ]; then
    return 1
  fi

  # Step 3: bind to most recent auto-promoted-by-m story (any status).
  local target_story
  target_story=$(grep -lE 'auto-promoted-by-m' "$fix/implementations/stories/"*.md 2>/dev/null | head -1)
  if [ -z "$target_story" ]; then
    return 2
  fi

  # Step 4a: append cooldown marker to source backlog file (NOW + 30 days).
  local cooldown_iso
  cooldown_iso=$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "+30 days" +%Y-%m-%dT%H:%M:%SZ)
  printf '<!-- auto-promote-cooldown: until %s -->\n' "$cooldown_iso" >> "$backlog_file"

  # Step 4b: set tracker auto_promote_paused_until (NOW + 24 hours).
  local pause_iso
  pause_iso=$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "+24 hours" +%Y-%m-%dT%H:%M:%SZ)
  jq --arg ts "$pause_iso" '.auto_promote_paused_until = $ts' "$tracker" > "$tracker.tmp"
  mv "$tracker.tmp" "$tracker"

  return 0
}

# -----------------------------------------------------------------------
# Per-case fixture builder
# -----------------------------------------------------------------------
new_fixture() {
  local fix; fix="$(mktemp -d)"
  mkdir -p "$fix/implementations/backlog" "$fix/implementations/stories" "$fix/implementations/.agents"
  cat > "$fix/implementations/.agents/m.json" <<'EOF'
{"last_user_prompt_ts": null, "afk_phrase_present": "1", "peers_alive": "1", "auto_promote_paused_until": null}
EOF
  printf '%s' "$fix"
}

backlog_file() {
  local fix="$1" id="$2" status="$3" concern="$4" size="$5" cooldown="${6:-}"
  local f="$fix/implementations/backlog/${id}-test.md"
  {
    echo "<!-- status: $status -->"
    echo "<!-- concern: $concern -->"
    echo "<!-- size: $size -->"
    if [ -n "$cooldown" ]; then echo "<!-- auto-promote-cooldown: until $cooldown -->"; fi
    echo "# Title"
  } > "$f"
}

story_file() {
  local fix="$1" id="$2" status="$3" auto_promoted="${4:-}"
  local f="$fix/implementations/stories/${id}-test.md"
  {
    echo "<!-- status: $status -->"
    if [ -n "$auto_promoted" ]; then echo "<!-- auto-promoted-by-m @ 2026-05-01T12:00:00Z -->"; fi
    echo "# Story"
  } > "$f"
}

# Case 1: all conditions met, one eligible item → that item is selected.
case_all_ok() {
  local fix; fix="$(new_fixture)"
  backlog_file "$fix" 100 accepted hygiene tiny
  local out; out=$(gate_decision "$fix")
  assert_eq "case1: all-ok → 100" "100" "$out"
  rm -rf "$fix"
}

# Case 2: AFK fails (recent prompt + no AFK phrase) → none.
case_afk_fails() {
  local fix; fix="$(new_fixture)"
  local recent; recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg ts "$recent" '.last_user_prompt_ts = $ts | .afk_phrase_present = "0"' "$fix/implementations/.agents/m.json" > "$fix/implementations/.agents/m.json.tmp"
  mv "$fix/implementations/.agents/m.json.tmp" "$fix/implementations/.agents/m.json"
  backlog_file "$fix" 200 accepted hygiene tiny
  local out; out=$(gate_decision "$fix")
  assert_eq "case2: AFK fails → none" "none" "$out"
  rm -rf "$fix"
}

# Case 3: Team idle fails (peers_alive=0) → none.
case_team_idle_fails() {
  local fix; fix="$(new_fixture)"
  jq '.peers_alive = "0"' "$fix/implementations/.agents/m.json" > "$fix/implementations/.agents/m.json.tmp"
  mv "$fix/implementations/.agents/m.json.tmp" "$fix/implementations/.agents/m.json"
  backlog_file "$fix" 300 accepted hygiene tiny
  local out; out=$(gate_decision "$fix")
  assert_eq "case3: team-idle fails → none" "none" "$out"
  rm -rf "$fix"
}

# Case 4: Eligibility fails (only feature/medium, no hygiene/tiny+small) → none.
case_eligibility_fails() {
  local fix; fix="$(new_fixture)"
  backlog_file "$fix" 400 accepted feature medium
  local out; out=$(gate_decision "$fix")
  assert_eq "case4: eligibility fails → none" "none" "$out"
  rm -rf "$fix"
}

# Case 5: Active cooldown on the only eligible item → none.
case_cooldown() {
  local fix; fix="$(new_fixture)"
  local future; future=$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+30 days" +%Y-%m-%dT%H:%M:%SZ)
  backlog_file "$fix" 500 accepted hygiene tiny "$future"
  local out; out=$(gate_decision "$fix")
  assert_eq "case5: active cooldown → none" "none" "$out"
  rm -rf "$fix"
}

# Case 6: Active global pause → none.
case_global_pause() {
  local fix; fix="$(new_fixture)"
  local future; future=$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+24 hours" +%Y-%m-%dT%H:%M:%SZ)
  jq --arg ts "$future" '.auto_promote_paused_until = $ts' "$fix/implementations/.agents/m.json" > "$fix/implementations/.agents/m.json.tmp"
  mv "$fix/implementations/.agents/m.json.tmp" "$fix/implementations/.agents/m.json"
  backlog_file "$fix" 600 accepted hygiene tiny
  local out; out=$(gate_decision "$fix")
  assert_eq "case6: global pause → none" "none" "$out"
  rm -rf "$fix"
}

# Case 7: Multiple eligible → tie-breaker (FIFO mtime, then concern, then size).
case_tiebreakers() {
  local fix; fix="$(new_fixture)"
  backlog_file "$fix" 701 accepted hygiene small
  sleep 1  # ensure mtime is later
  backlog_file "$fix" 702 accepted hygiene tiny
  # 701 has older mtime → wins on FIFO
  local out; out=$(gate_decision "$fix")
  assert_eq "case7: FIFO mtime wins → 701" "701" "$out"
  rm -rf "$fix"
}

# Case 8: in-flight auto-promotion blocks new auto-promotion → none.
case_inflight_auto_promo() {
  local fix; fix="$(new_fixture)"
  backlog_file "$fix" 800 accepted hygiene tiny
  story_file "$fix" 801 in-progress auto-promoted
  local out; out=$(gate_decision "$fix")
  assert_eq "case8: in-flight auto-promotion → none" "none" "$out"
  rm -rf "$fix"
}

# Case 9 (Story 018, sprint 2026-05-01 retro FINDING-1): disapproval-brake
# side-effects. Exercises the brake matcher + cooldown-marker write +
# tracker pause write — gap-coverage for the Story 014 / Section D brake.
case_brake() {
  local fix; fix="$(new_fixture)"
  # Source backlog: the item the human is disapproving of.
  backlog_file "$fix" 900 accepted hygiene tiny
  # Most recent auto-promoted-by-m story (the one the brake binds to).
  story_file "$fix" 901 in-progress auto-promoted
  # Mocked bus: a user-prompt-submit-hook line containing the brake phrase "nope".
  local bus="$fix/implementations/.message-bus.jsonl"
  cat > "$bus" <<'BUS'
{"ts":"2026-05-02T12:00:00Z","from":"manager-test","to":"*","type":"<user-prompt-submit-hook>","payload":"Nope, undo that auto-promoted story please"}
BUS

  # Run the brake.
  if ! gate_brake "$fix" "900-test.md"; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case9: gate_brake returned non-zero (no bind)")
    rm -rf "$fix"; return
  fi

  # Assertion 1: cooldown marker appended to source backlog file.
  if grep -qE '^<!-- auto-promote-cooldown: until [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$fix/implementations/backlog/900-test.md"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case9: cooldown marker not appended to 900-test.md")
  fi

  # Assertion 2: tracker auto_promote_paused_until set to a non-null ISO.
  local paused_until
  paused_until=$(jq -r '.auto_promote_paused_until // ""' "$fix/implementations/.agents/m.json")
  if [ -n "$paused_until" ] && [ "$paused_until" != "null" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case9: auto_promote_paused_until not set in tracker (got '$paused_until')")
  fi

  # Assertion 3: pause is in [23h, 25h] window (24h ± 1h tolerance).
  if [ -n "$paused_until" ] && [ "$paused_until" != "null" ]; then
    local pause_epoch now_epoch delta
    pause_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$paused_until" +%s 2>/dev/null \
      || date -u -d "$paused_until" +%s 2>/dev/null)
    now_epoch=$(date -u +%s)
    delta=$((pause_epoch - now_epoch))
    if [ "$delta" -ge 82800 ] && [ "$delta" -le 90000 ]; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1))
      FAILED_CASES+=("case9: pause window out of [23h, 25h] band (delta=${delta}s)")
    fi
  fi

  # Assertion 4: cooldown is in [29d, 31d] window (30d ± 1d tolerance).
  local cooldown_iso
  cooldown_iso=$(grep -oE 'auto-promote-cooldown: until [^ ]+' "$fix/implementations/backlog/900-test.md" \
    | head -1 | awk '{print $3}' | tr -d '>')
  if [ -n "$cooldown_iso" ]; then
    local cd_epoch now_epoch delta
    cd_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$cooldown_iso" +%s 2>/dev/null \
      || date -u -d "$cooldown_iso" +%s 2>/dev/null)
    now_epoch=$(date -u +%s)
    delta=$((cd_epoch - now_epoch))
    # 29d = 2505600s; 31d = 2678400s
    if [ "$delta" -ge 2505600 ] && [ "$delta" -le 2678400 ]; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1))
      FAILED_CASES+=("case9: cooldown window out of [29d, 31d] band (delta=${delta}s)")
    fi
  fi

  rm -rf "$fix"
}

case_all_ok
case_afk_fails
case_team_idle_fails
case_eligibility_fails
case_cooldown
case_global_pause
case_tiebreakers
case_inflight_auto_promo
case_brake

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
