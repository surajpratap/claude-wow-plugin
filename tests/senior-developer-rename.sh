#!/usr/bin/env bash
# Story 059 — bus-tail.sh accepts both new (senior-developer-*) and legacy
# (senior-dev-*) addressing when role is "senior-developer". Exact-ID forms
# also covered. Stderr deprecation telemetry fires on legacy `to` matches
# only (never on `from` — receive routing is to-only per PP review-fix).
#
# Cases:
# 1. role=senior-developer + to: "senior-developer-*" (new glob) → matches
# 2. role=senior-developer + to: "senior-dev-*" (legacy glob) → matches AND
#    fires stderr deprecation
# 3. role=senior-developer + agent_id matches new exact form, line addresses
#    that exact ID with new prefix → matches via $id branch
# 4. role=senior-developer + agent_id matches OLD exact form, line addresses
#    that old exact ID → matches via $id branch (running pre-rename SD whose
#    new prompt sets ROLE=senior-developer but agent_id is still old) AND
#    fires stderr deprecation (legacy `to`)
# 5. Combined: legacy stderr fires for cases 2 + 4; does NOT fire for cases
#    1 + 3 (regression guard for the false-positive class PP caught)

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
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

assert_not_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) FAIL=$((FAIL+1))
                 FAILED_CASES+=("$name (haystack unexpectedly contains '$needle')") ;;
    *) PASS=$((PASS+1)) ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUS_TAIL="$REPO_ROOT/scripts/wow-process/bus-tail.sh"

SPAWNED_PIDS=(); TEST_DIRS=()
cleanup() {
  for pid in "${SPAWNED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    for c in $(pgrep -P "$pid" 2>/dev/null); do kill -KILL "$c" 2>/dev/null || true; done
    kill -KILL "$pid" 2>/dev/null || true
  done
  for d in "${TEST_DIRS[@]:-}"; do
    [ -n "$d" ] || continue
    pkill -f "$d" 2>/dev/null || true
    pkill -f "idle-monitor[.]py.* --project[= ]$d" 2>/dev/null || true
    pkill -f "bus-tail[.]sh .*$d" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# Run bus-tail in background, append fixture lines, capture stdout + stderr,
# wait for the timeout. Returns "stdout|||stderr".
run_tail_with_fixture() {
  local agent_id="$1"; local role="$2"; shift 2
  local tdir
  tdir=$(mktemp -d)
  TEST_DIRS+=("$tdir")
  mkdir -p "$tdir/.agents"
  local bus="$tdir/bus.jsonl"
  truncate -s 0 "$bus"
  local out="$tdir/out" err="$tdir/err"

  ( timeout 2 bash "$BUS_TAIL" "$bus" "$agent_id" "$role" > "$out" 2> "$err" ) &
  local btpid=$!
  SPAWNED_PIDS+=("$btpid")
  sleep 0.4
  for line in "$@"; do
    printf '%s\n' "$line" >> "$bus"
  done
  wait "$btpid" 2>/dev/null
  local stdout stderr
  stdout=$(grep -v '^\[bus-tail-' "$out" 2>/dev/null || true)
  stderr=$(cat "$err" 2>/dev/null || true)
  rm -rf "$tdir"
  printf '%s|||%s' "$stdout" "$stderr"
}

# -----------------------------------------------------------------------------
# Case 1: role=senior-developer + to: "senior-developer-*" (new glob) → matches
# -----------------------------------------------------------------------------
LINE1='{"ts":"2026-01-01T00:00:00Z","from":"manager-X","to":"senior-developer-*","type":"foo","payload":"new-form"}'
RESULT=$(run_tail_with_fixture "senior-developer-test" "senior-developer" "$LINE1")
OUT1=${RESULT%%|||*}
assert_contains "case-1-new-glob-matches" "new-form" "$OUT1"

# -----------------------------------------------------------------------------
# Case 2: legacy glob → matches AND fires stderr deprecation
# -----------------------------------------------------------------------------
LINE2='{"ts":"2026-01-01T00:00:01Z","from":"manager-X","to":"senior-dev-*","type":"foo","payload":"old-form"}'
RESULT=$(run_tail_with_fixture "senior-developer-test" "senior-developer" "$LINE2")
OUT2=${RESULT%%|||*}; ERR2=${RESULT##*|||}
assert_contains "case-2-legacy-glob-matches" "old-form" "$OUT2"
assert_contains "case-2-legacy-glob-stderr" "[bus-tail-deprecated-glob]" "$ERR2"

# -----------------------------------------------------------------------------
# Case 3: exact new-form ID → matches via $id branch
# -----------------------------------------------------------------------------
LINE3='{"ts":"2026-01-01T00:00:02Z","from":"manager-X","to":"senior-developer-20260101T120000-abc123","type":"foo","payload":"exact-new"}'
RESULT=$(run_tail_with_fixture "senior-developer-20260101T120000-abc123" "senior-developer" "$LINE3")
OUT3=${RESULT%%|||*}; ERR3=${RESULT##*|||}
assert_contains "case-3-new-exact-id-matches" "exact-new" "$OUT3"
assert_not_contains "case-3-new-exact-no-deprecation" "[bus-tail-deprecated-glob]" "$ERR3"

# -----------------------------------------------------------------------------
# Case 4: exact OLD-form ID + role=senior-developer (running pre-rename SD)
#         → matches via $id branch AND fires stderr deprecation
# -----------------------------------------------------------------------------
LINE4='{"ts":"2026-01-01T00:00:03Z","from":"manager-X","to":"senior-dev-20260101T120000-abc123","type":"foo","payload":"exact-old"}'
RESULT=$(run_tail_with_fixture "senior-dev-20260101T120000-abc123" "senior-developer" "$LINE4")
OUT4=${RESULT%%|||*}; ERR4=${RESULT##*|||}
assert_contains "case-4-old-exact-id-matches" "exact-old" "$OUT4"
assert_contains "case-4-old-exact-id-stderr" "[bus-tail-deprecated-glob]" "$ERR4"

# -----------------------------------------------------------------------------
# Case 5 (regression guard for PP review-fix): receive routing is `to`-only;
#         a message FROM an old-form SD addressed TO another role must NOT
#         match (no false-positive). Also: cases 1 + 3 must NOT fire stderr.
# -----------------------------------------------------------------------------
LINE5='{"ts":"2026-01-01T00:00:04Z","from":"senior-dev-Y","to":"tester-*","type":"foo","payload":"to-other-from-old"}'
RESULT=$(run_tail_with_fixture "senior-developer-test" "senior-developer" "$LINE5")
OUT5=${RESULT%%|||*}; ERR5=${RESULT##*|||}
assert_not_contains "case-5-cross-agent-not-matched" "to-other-from-old" "$OUT5"
assert_not_contains "case-5-cross-agent-no-stderr" "[bus-tail-deprecated-glob]" "$ERR5"

echo
echo "senior-developer-rename: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
