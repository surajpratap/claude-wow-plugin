#!/usr/bin/env bash
# Story 076 — idle-monitor.py --check-predicate three branches: idle, busy,
# no-required-agents. Preserves the test contract from manager-monitor.py.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="$ROOT/scripts/wow-process/idle-monitor.py"

if [ ! -f "$PY" ]; then
  echo "idle-monitor-check-predicate: SKIP — $PY not found"
  exit 0
fi

mk_fixture() {
  local d activity_type include_activity
  activity_type="${1:-stop}"
  include_activity="${2:-yes}"
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/.claude/.session-role-by-claude-pid" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  echo "manager" > "$d/.claude/.session-role-by-claude-pid/$$"
  if [ "$include_activity" = "yes" ]; then
    printf '{"ts":"2026-05-15T00:00:00Z","claude_pid":%d,"role":"manager","type":"%s"}\n' \
      "$$" "$activity_type" > "$d/implementations/.activity.jsonl"
  fi
  echo "$d"
}

# Case 1: idle — all required pids' latest activity is `stop`/`stop_failure`.
P1=$(mk_fixture "stop")
OUT1=$(CLAUDE_PROJECT_DIR="$P1" python3 "$PY" --check-predicate 2>/dev/null)
assert_eq "case-1-idle" "idle" "$OUT1"
rm -rf "$P1"

P1b=$(mk_fixture "stop_failure")
OUT1b=$(CLAUDE_PROJECT_DIR="$P1b" python3 "$PY" --check-predicate 2>/dev/null)
assert_eq "case-1b-stop_failure-is-also-idle" "idle" "$OUT1b"
rm -rf "$P1b"

# Case 2: busy — at least one required pid has a non-terminal latest activity.
P2=$(mk_fixture "tool_use")
OUT2=$(CLAUDE_PROJECT_DIR="$P2" python3 "$PY" --check-predicate 2>/dev/null)
assert_eq "case-2-busy" "busy" "$OUT2"
rm -rf "$P2"

# Case 2b (Story 110): a required PID present but with NO activity row is
# treated as a foreign/stale-marker PID — skipped, not "busy". With this PID
# being the only one in the marker dir, the cohort is empty after skip ⇒
# "no-required-agents". The pre-Story-110 behavior of "busy" silently
# poisoned the all-idle nudge for any foreign claude PID with a marker.
P2b=$(mk_fixture "stop" "no")
OUT2b=$(CLAUDE_PROJECT_DIR="$P2b" python3 "$PY" --check-predicate 2>/dev/null)
assert_eq "case-2b-no-activity-row-yields-no-required-agents" "no-required-agents" "$OUT2b"
rm -rf "$P2b"

# Case 3: no-required-agents — empty marker dir.
P3=$(mktemp -d)
mkdir -p "$P3/.claude-plugin" "$P3/.claude/.session-role-by-claude-pid" "$P3/implementations"
echo '{"name":"x","version":"0.0.0"}' > "$P3/.claude-plugin/plugin.json"
OUT3=$(CLAUDE_PROJECT_DIR="$P3" python3 "$PY" --check-predicate 2>/dev/null)
assert_eq "case-3-no-required-agents" "no-required-agents" "$OUT3"
rm -rf "$P3"

# Case 3b: marker present but role not in REQUIRED_ROLES → still no-required-agents.
P3b=$(mktemp -d)
mkdir -p "$P3b/.claude-plugin" "$P3b/.claude/.session-role-by-claude-pid" "$P3b/implementations"
echo '{"name":"x","version":"0.0.0"}' > "$P3b/.claude-plugin/plugin.json"
echo "slacker" > "$P3b/.claude/.session-role-by-claude-pid/$$"
OUT3b=$(CLAUDE_PROJECT_DIR="$P3b" python3 "$PY" --check-predicate 2>/dev/null)
assert_eq "case-3b-non-required-role-only" "no-required-agents" "$OUT3b"
rm -rf "$P3b"

echo "idle-monitor-check-predicate: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
