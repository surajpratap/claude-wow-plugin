#!/usr/bin/env bash
# Story 017 / Section H — slack-bridge spawn lifecycle test.
#
# Synthetic-fixture bash test mirroring tests/manager-pre-sleep-liveness.sh.
# Each case sets up a temp tree (mocked bridge dir + mocked tracker + bus),
# calls inline helpers that mirror S's prompt logic for the spawn flow
# (Section D), and asserts the side-effects.
#
# No real `node` invocation; no actual HTTP server. The helpers verify the
# command-shape, dep-cache logic, PID-read retry, and degraded-mode emit
# at the bash level — production source under bridge/slack/src/ is exercised
# separately by bridge/slack/tests/smoke.test.ts (npm test wrapper).

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

assert_match() {
  local name="$1"; local pattern="$2"; local actual="$3"
  if printf '%s' "$actual" | grep -qE "$pattern"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (pattern '$pattern' not found in '$actual')")
  fi
}

# -----------------------------------------------------------------------------
# Helpers — mirror S's prompt logic for the spawn flow.
# -----------------------------------------------------------------------------

# dep_install_needed <bridge-dir>
#   Echoes "yes" if .deps-installed is missing OR doesn't match sha1(package-lock.json).
#   Echoes "no" if it matches (skip install).
dep_install_needed() {
  local dir="$1"
  local sentinel="$dir/.deps-installed"
  local lockfile="$dir/package-lock.json"
  if [ ! -f "$sentinel" ] || [ ! -f "$lockfile" ]; then
    echo "yes"
    return
  fi
  local current saved
  current=$(shasum -a 1 "$lockfile" 2>/dev/null | awk '{print $1}')
  saved=$(cat "$sentinel")
  if [ "$current" = "$saved" ]; then
    echo "no"
  else
    echo "yes"
  fi
}

# build_spawn_command <bridge-dir> <port> <bot-token> <app-token> <events-path>
#   Echoes the exact spawn command shape S would invoke.
#   NOTE (v2): env vars are SLACK_BOT_TOKEN + SLACK_APP_TOKEN (Bolt convention),
#   NOT SLACK_TOKEN/WORKSPACE/CHANNEL. Workspace + channel are NOT cred fields.
build_spawn_command() {
  local dir="$1" port="$2" bot_token="$3" app_token="$4" events="$5"
  printf 'cd %s && PORT=%s SLACK_BOT_TOKEN=%s SLACK_APP_TOKEN=%s EVENTS_PATH=%s exec node dist/index.js' \
    "$dir" "$port" "$bot_token" "$app_token" "$events"
}

# read_pid_with_retry <pid-file> <max-retries> <interval-ms>
#   Polls for the file; returns the PID. Empty string if exhausted.
read_pid_with_retry() {
  local pid_file="$1" max="$2" interval_ms="$3"
  local i=0
  while [ "$i" -lt "$max" ]; do
    if [ -f "$pid_file" ]; then
      cat "$pid_file"
      return 0
    fi
    sleep "$(awk -v ms="$interval_ms" 'BEGIN{print ms/1000}')"
    i=$((i+1))
  done
  return 1
}

# spawn_decide <fixture-dir>
#   Mirrors the S startup decision tree: sentinel check → cred check → spawn or degraded.
#   Echoes one of: disabled / spawn / degraded:<reason>.
spawn_decide() {
  local fix="$1"
  if [ -f "$fix/implementations/.slack/disabled" ]; then
    echo "disabled"
    return
  fi
  local creds="$fix/.wow-kindflow/slack/myproj/creds.json"
  if [ ! -f "$creds" ]; then
    echo "degraded:no-creds"
    return
  fi
  if [ "${MOCK_NO_NODE:-0}" = "1" ]; then
    echo "degraded:no-node"
    return
  fi
  echo "spawn"
}

# emit_bridge_status <bus-path> <state> <reason>
emit_bridge_status() {
  local bus="$1" state="$2" reason="$3"
  printf '{"ts":"2026-05-02T00:00:00Z","from":"slacker-test","to":"manager-*","type":"bridge-status","payload":{"state":"%s","reason":"%s"}}\n' "$state" "$reason" >> "$bus"
}

# update_tracker <tracker> <key> <value>
update_tracker() {
  local tracker="$1" key="$2" value="$3"
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$tracker" > "$tracker.tmp"
  mv "$tracker.tmp" "$tracker"
}

# -----------------------------------------------------------------------------
# Fixture builder
# -----------------------------------------------------------------------------

new_fixture() {
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/implementations/.slack" "$dir/implementations/.agents" "$dir/.wow-kindflow/slack/myproj" "$dir/bridge/slack"
  : > "$dir/implementations/.message-bus.jsonl"
  echo '{}' > "$dir/implementations/.agents/s.json"
  # Default cred file (cases that test no-cred remove it).
  # NEW v2 shape: bot_token + app_token (Bolt Socket Mode), not token+workspace+channel.
  cat > "$dir/.wow-kindflow/slack/myproj/creds.json" <<'JSON'
{"bot_token":"xoxb-test","app_token":"xapp-test","schema_version":"1.0.0"}
JSON
  chmod 0600 "$dir/.wow-kindflow/slack/myproj/creds.json"
  # Mocked package-lock so the SHA hash works.
  cat > "$dir/bridge/slack/package-lock.json" <<'JSON'
{"name":"@claude-wow-plugin/slack-bridge","lockfileVersion":3,"requires":true,"packages":{}}
JSON
  echo "$dir"
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: dep cache hit → skip install.
DIR=$(new_fixture)
LOCK_SHA=$(shasum -a 1 "$DIR/bridge/slack/package-lock.json" | awk '{print $1}')
echo "$LOCK_SHA" > "$DIR/bridge/slack/.deps-installed"
RESULT=$(dep_install_needed "$DIR/bridge/slack")
assert_eq "case-1-dep-cache-hit-skips-install" "no" "$RESULT"
rm -rf "$DIR"

# Case 2: dep cache miss → install needed.
DIR=$(new_fixture)
echo "stale-sha" > "$DIR/bridge/slack/.deps-installed"
RESULT=$(dep_install_needed "$DIR/bridge/slack")
assert_eq "case-2-dep-cache-miss-runs-install" "yes" "$RESULT"
rm -rf "$DIR"

# Case 2b: no .deps-installed file at all → install needed.
DIR=$(new_fixture)
RESULT=$(dep_install_needed "$DIR/bridge/slack")
assert_eq "case-2b-no-sentinel-runs-install" "yes" "$RESULT"
rm -rf "$DIR"

# Case 3: spawn command shape includes new (Bolt) env vars.
DIR=$(new_fixture)
CMD=$(build_spawn_command "$DIR/bridge/slack" "47823" "xoxb-x" "xapp-y" "$DIR/implementations/.slack/events.jsonl")
assert_match "case-3-spawn-cd-bridge-dir" "^cd $DIR/bridge/slack" "$CMD"
assert_match "case-3-spawn-PORT" "PORT=47823" "$CMD"
assert_match "case-3-spawn-SLACK_BOT_TOKEN" "SLACK_BOT_TOKEN=xoxb-x" "$CMD"
assert_match "case-3-spawn-SLACK_APP_TOKEN" "SLACK_APP_TOKEN=xapp-y" "$CMD"
# Verify WORKSPACE/CHANNEL are NOT present (anti-assertion):
if printf '%s' "$CMD" | grep -qE 'WORKSPACE=|CHANNEL='; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case-3-spawn-no-legacy-env-vars (CMD contains WORKSPACE= or CHANNEL=, should not in v2.16.0+)")
else
  PASS=$((PASS+1))
fi
assert_match "case-3-spawn-exec-node" "exec node dist/index\\.js" "$CMD"
rm -rf "$DIR"

# Case 4: PID read with retry — file appears on retry 3 (~300ms).
DIR=$(new_fixture)
PID_FILE="$DIR/implementations/.slack/.bridge-pid"
( sleep 0.25 && echo "12345" > "$PID_FILE" ) &
RESULT=$(read_pid_with_retry "$PID_FILE" 5 100)
RC=$?
assert_eq "case-4-pid-read-with-retry" "12345" "$RESULT"
assert_eq "case-4-pid-read-rc" "0" "$RC"
wait
rm -rf "$DIR"

# Case 5: spawn-fail (no node) → degraded state + bus emit.
DIR=$(new_fixture)
MOCK_NO_NODE=1
DECISION=$(spawn_decide "$DIR")
assert_eq "case-5-no-node-degraded" "degraded:no-node" "$DECISION"
emit_bridge_status "$DIR/implementations/.message-bus.jsonl" "stopped" "no-node"
update_tracker "$DIR/implementations/.agents/s.json" "slack_bridge_state" "stopped"
LAST_LINE=$(tail -1 "$DIR/implementations/.message-bus.jsonl")
assert_match "case-5-bus-emit-bridge-status" '"type":"bridge-status"' "$LAST_LINE"
assert_match "case-5-bus-emit-state-stopped" '"state":"stopped"' "$LAST_LINE"
TRACKER_STATE=$(jq -r '.slack_bridge_state' "$DIR/implementations/.agents/s.json")
assert_eq "case-5-tracker-state-stopped" "stopped" "$TRACKER_STATE"
unset MOCK_NO_NODE
rm -rf "$DIR"

# Case 6: sentinel disables spawn → no Monitor created, tracker disabled.
DIR=$(new_fixture)
touch "$DIR/implementations/.slack/disabled"
DECISION=$(spawn_decide "$DIR")
assert_eq "case-6-sentinel-disabled" "disabled" "$DECISION"
update_tracker "$DIR/implementations/.agents/s.json" "slack_bridge_state" "disabled"
TRACKER_STATE=$(jq -r '.slack_bridge_state' "$DIR/implementations/.agents/s.json")
assert_eq "case-6-tracker-state-disabled" "disabled" "$TRACKER_STATE"
# Bus should be empty (no emit on sentinel-disabled).
BUS_LINES=$(wc -l < "$DIR/implementations/.message-bus.jsonl" | tr -d ' ')
assert_eq "case-6-bus-no-emit-on-disabled" "0" "$BUS_LINES"
rm -rf "$DIR"

# Case 7: cred check — missing creds → degraded:no-creds.
DIR=$(new_fixture)
rm "$DIR/.wow-kindflow/slack/myproj/creds.json"
DECISION=$(spawn_decide "$DIR")
assert_eq "case-7-no-creds-degraded" "degraded:no-creds" "$DECISION"
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "slack-bridge-spawn: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
