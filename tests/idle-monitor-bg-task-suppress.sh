#!/usr/bin/env bash
# Story 098 — idle-monitor background-task suppression.
#   Group A: check_predicate stays `busy` when a stop'd peer's current
#            stop-episode contains a bg-spawn row.
#   Group B: log-activity.sh types a backgrounded Bash as bg-spawn; every
#            other tool call (foreground Bash, Monitor) stays type:tool.
#   Group C: the all-idle-nudge stdout emission honors the suppression.

set -u

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="$ROOT/scripts/wow-process/idle-monitor.py"
HOOK="$ROOT/scripts/hooks/log-activity.sh"

if [ ! -f "$PY" ] || [ ! -f "$HOOK" ]; then
  echo "idle-monitor-bg-task-suppress: SKIP — idle-monitor.py or log-activity.sh not found"
  exit 0
fi

# Story 143: the bg-busy predicate is now time-bound (busy iff most-recent
# bg-spawn <= BG_BUSY_MAX_AGE_SECONDS old). These fixtures use a fixed
# 2026-05-15T00:00:00Z ts, so pin "now" to 60s after it — the bg-spawn rows then
# count as recent (within the window), preserving the Story-098 busy assertions.
# (all-idle-nudge keys off check_predicate=idle, which is ts-independent, so the
# idle cases still fire.)
WOW_IDLE_NOW_EPOCH="$(python3 -c 'import datetime; print(int(datetime.datetime(2026,5,15,0,1,0,tzinfo=datetime.timezone.utc).timestamp()))')"
export WOW_IDLE_NOW_EPOCH

# Fixture: a project dir with one live manager PID ($$) and an ordered
# activity-row list for that PID (args oldest-first).
mk_fixture_rows() {
  local d t; d=$(mktemp -d)
  TEST_DIRS+=("$d")
  mkdir -p "$d/.claude-plugin" "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  echo "manager" > "$d/.claude/.session-role-by-claude-pid/$$"
  for t in "$@"; do
    printf '{"ts":"2026-05-15T00:00:00Z","claude_pid":%d,"role":"manager","type":"%s"}\n' \
      "$$" "$t" >> "$d/implementations/.activity.jsonl"
  done
  echo "$d"
}

# ===== Group A — check_predicate reading logic =====
PA=$(mk_fixture_rows prompt_in tool stop)
assert_eq "A-a-idle-no-bg" "idle" \
  "$(CLAUDE_PROJECT_DIR="$PA" python3 "$PY" --check-predicate 2>/dev/null)"
rm -rf "$PA"

PB=$(mk_fixture_rows prompt_in tool bg-spawn stop)
assert_eq "A-b-stop-with-outstanding-bg" "busy" \
  "$(CLAUDE_PROJECT_DIR="$PB" python3 "$PY" --check-predicate 2>/dev/null)"
rm -rf "$PB"

# Story 143 CHANGED this: resumed work (tool/tool) after a bg-spawn used to read
# idle ("bg-completed" — the clause-(i) assumption). But the activity log CANNOT
# distinguish "bg finished, peer resumed" from "bg still running, peer woke for
# an unrelated reason" (the exact bug). M-confirmed design drops clause (i): a
# recent bg-spawn stays BUSY until the time-bound cap, regardless of later rows.
# (Was "idle" pre-143.)
PC=$(mk_fixture_rows prompt_in tool bg-spawn stop tool tool stop)
assert_eq "A-c-resumed-after-bg-now-busy (Story 143)" "busy" \
  "$(CLAUDE_PROJECT_DIR="$PC" python3 "$PY" --check-predicate 2>/dev/null)"
rm -rf "$PC"

PD=$(mk_fixture_rows prompt_in tool bg-spawn)
assert_eq "A-d-bg-spawn-latest-row" "busy" \
  "$(CLAUDE_PROJECT_DIR="$PD" python3 "$PY" --check-predicate 2>/dev/null)"
rm -rf "$PD"

# Story 143 CHANGED this: a bg-spawn in a PRIOR episode (here followed by
# stop/tool/stop) used to read idle (Story-098 current-episode-only check) — the
# exact cross-episode bug 143 fixes. With the time-bound predicate + now pinned
# 60s after the fixture ts, the bg-spawn is recent → BUSY. (Was "idle" pre-143.)
PE=$(mk_fixture_rows bg-spawn stop tool stop)
assert_eq "A-e-cross-episode-bg-now-busy (Story 143)" "busy" \
  "$(CLAUDE_PROJECT_DIR="$PE" python3 "$PY" --check-predicate 2>/dev/null)"
rm -rf "$PE"

# ===== Group B — log-activity.sh emission =====
# The hook reads $PPID for its role marker. emit_row is a function called
# DIRECTLY (not in a command-substitution subshell), so `bash "$HOOK"`'s parent
# is this test shell — name the marker with $$ (portable; stable in subshells).
emit_row() {
  local name="$1" stdin="$2" expected="$3" d got
  d=$(mktemp -d)
  TEST_DIRS+=("$d")
  mkdir -p "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo "manager" > "$d/.claude/.session-role-by-claude-pid/$$"
  CLAUDE_PROJECT_DIR="$d" bash "$HOOK" <<<"$stdin" 2>/dev/null
  got=$(tail -1 "$d/implementations/.activity.jsonl" 2>/dev/null | jq -r '.type // empty' 2>/dev/null)
  assert_eq "$name" "$expected" "$got"
  rm -rf "$d"
}

emit_row "B-f-bg-bash-is-bg-spawn" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"run_in_background":true}}' "bg-spawn"
emit_row "B-g-foreground-bash-is-tool" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' "tool"
emit_row "B-h-monitor-is-tool" \
  '{"hook_event_name":"PreToolUse","tool_name":"Monitor","tool_input":{"command":"x"}}' "tool"

# ===== Group C — stdout emission honors the suppression =====
# Mirror idle-monitor-stdout-emit.sh: run the loop, the first tick fires
# immediately, kill after a short window, inspect stdout.
run_one_tick() {
  local d="$1" out pid; out=$(mktemp)
  CLAUDE_PROJECT_DIR="$d" python3 "$PY" > "$out" 2>/dev/null &
  pid=$!
  SPAWNED_PIDS+=("$pid")
  sleep 3
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$out"; rm -f "$out"
}

PI=$(mk_fixture_rows prompt_in tool stop)
OUT_I=$(run_one_tick "$PI")
assert_eq "C-i-idle-emits-nudge" "all-idle-nudge" \
  "$(echo "$OUT_I" | head -1 | jq -r '.type // empty' 2>/dev/null)"
rm -rf "$PI"

PJ=$(mk_fixture_rows prompt_in tool bg-spawn stop)
OUT_J=$(run_one_tick "$PJ")
assert_eq "C-j-outstanding-bg-no-nudge" "0" "$(printf '%s' "$OUT_J" | wc -c | tr -d ' ')"
rm -rf "$PJ"

echo "idle-monitor-bg-task-suppress: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
