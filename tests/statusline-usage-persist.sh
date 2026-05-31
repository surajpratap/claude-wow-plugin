#!/usr/bin/env bash
# Story 172 — delegating statusline wrapper `statusline-usage-persist.sh`.
#
# Behavioral (drives the real wrapper with fixture stdin + injectable
# state-file path + a recorded-original command). Cases:
#   (a) persist: stdin carries .rate_limits.five_hour.used_percentage →
#       the state file is written atomically with the full schema.
#   (b) delegate: the SAME stdin is piped to the recorded original command;
#       its stdout AND exit code pass through unchanged (the input=$(cat)
#       delegate contract — newline-bearing JSON survives, exit propagates).
#   (c) absent-no-op: stdin lacks the rate_limits fields → NO state file is
#       written, the wrapper still delegates cleanly (exit 0).
#   (d) idempotent install: --install on a settings.json re-points
#       statusLine.command to the wrapper + records the original; a second
#       --install is a no-op (already active, original preserved).
#   (e) opt-out restore: --uninstall restores the recorded original command.
#
# RED-WITHOUT: patch .red-without/statusline-persist-delegate.patch -> b-delegate-stdout-passthrough
# RED-WITHOUT: patch .red-without/statusline-persist-noop-guard.patch -> c-absent-no-state-file

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
WRAPPER="$ROOT/scripts/wow-process/statusline-usage-persist.sh"

if [ ! -f "$WRAPPER" ]; then
  echo "statusline-usage-persist: SKIP — $WRAPPER not found"
  exit 0
fi

# A recorded-original statusline command: echoes a marker + reads its own
# stdin so we can prove the wrapper piped the SAME bytes through. Writes the
# bytes it received to $SEEN, exits with a chosen code so we can assert the
# exit passthrough.
FIXTURE_BIN="$(mktemp -d)"
SEEN="$FIXTURE_BIN/seen.txt"
cat > "$FIXTURE_BIN/orig.sh" <<EOF
#!/usr/bin/env bash
cat > "$SEEN"
printf 'ORIGINAL-STATUSLINE-RENDER'
exit 7
EOF
chmod +x "$FIXTURE_BIN/orig.sh"
ORIG_CMD="bash $FIXTURE_BIN/orig.sh"

# ---- (a)+(b) persist + delegate contract ----
D=$(mktemp -d)
STATE="$D/five-hour-usage.json"
STDIN_JSON='{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":"2026-05-31T18:00:00Z"},"seven_day":{"used_percentage":11,"resets_at":"2026-06-05T00:00:00Z"}},"other":"x"}'
# Feed JSON WITH a trailing newline; the original must see the same content.
OUT=$(printf '%s\n' "$STDIN_JSON" | \
  WOW_USAGE_STATE_FILE="$STATE" WOW_STATUSLINE_ORIGINAL_CMD="$ORIG_CMD" \
  bash "$WRAPPER")
RC=$?
assert_eq "b-delegate-exit-passthrough" "7" "$RC"
assert_eq "b-delegate-stdout-passthrough" "ORIGINAL-STATUSLINE-RENDER" "$OUT"
# The original saw the same JSON payload (input=$(cat) contract — content,
# not byte-identical trailing-newline: assert the JSON parses identically).
SEEN_FIVE=$(jq -r '.rate_limits.five_hour.used_percentage' < "$SEEN" 2>/dev/null)
assert_eq "b-delegate-stdin-content" "42" "$SEEN_FIVE"
# State file written atomically with the full schema.
assert_eq "a-persist-five-pct"  "42" "$(jq -r '.five_hour.used_percentage' "$STATE" 2>/dev/null)"
assert_eq "a-persist-five-reset" "2026-05-31T18:00:00Z" "$(jq -r '.five_hour.resets_at' "$STATE" 2>/dev/null)"
assert_eq "a-persist-seven-pct"  "11" "$(jq -r '.seven_day.used_percentage' "$STATE" 2>/dev/null)"
assert_eq "a-persist-seven-reset" "2026-06-05T00:00:00Z" "$(jq -r '.seven_day.resets_at' "$STATE" 2>/dev/null)"
HAS_TS=$(jq -r 'has("captured_ts")' "$STATE" 2>/dev/null)
assert_eq "a-persist-has-captured-ts" "true" "$HAS_TS"
rm -rf "$D"

# ---- (c) absent fields → no state file, clean delegate (exit passthrough) ----
DC=$(mktemp -d)
STATE_C="$DC/five-hour-usage.json"
ABSENT_JSON='{"model":{"id":"x"},"workspace":{"current_dir":"/tmp"}}'
OUT_C=$(printf '%s' "$ABSENT_JSON" | \
  WOW_USAGE_STATE_FILE="$STATE_C" WOW_STATUSLINE_ORIGINAL_CMD="$ORIG_CMD" \
  bash "$WRAPPER")
RC_C=$?
assert_eq "c-absent-no-state-file" "absent" "$([ -e "$STATE_C" ] && echo present || echo absent)"
assert_eq "c-absent-still-delegates-stdout" "ORIGINAL-STATUSLINE-RENDER" "$OUT_C"
assert_eq "c-absent-still-delegates-exit" "7" "$RC_C"
rm -rf "$DC"

# ---- (d) idempotent install ----
DI=$(mktemp -d)
SETTINGS="$DI/settings.json"
echo '{"statusLine":{"type":"command","command":"my-original-statusline --foo"}}' > "$SETTINGS"
bash "$WRAPPER" --install "$SETTINGS" >/dev/null 2>&1
INSTALL_RC=$?
assert_eq "d-install-exit-0" "0" "$INSTALL_RC"
# statusLine.command now points at the wrapper.
CMD_AFTER=$(jq -r '.statusLine.command' "$SETTINGS")
case "$CMD_AFTER" in
  *statusline-usage-persist.sh*) assert_eq "d-install-repoints-to-wrapper" "yes" "yes" ;;
  *) assert_eq "d-install-repoints-to-wrapper" "yes" "no ($CMD_AFTER)" ;;
esac
# The original was recorded (recoverable for delegate + restore).
RECORDED=$(jq -r '.statusLine.wowOriginalCommand // empty' "$SETTINGS")
assert_eq "d-install-records-original" "my-original-statusline --foo" "$RECORDED"
# Second install is a no-op: original NOT clobbered with the wrapper command.
bash "$WRAPPER" --install "$SETTINGS" >/dev/null 2>&1
RECORDED2=$(jq -r '.statusLine.wowOriginalCommand // empty' "$SETTINGS")
assert_eq "d-install-idempotent-original-preserved" "my-original-statusline --foo" "$RECORDED2"

# ---- (e) opt-out restore ----
bash "$WRAPPER" --uninstall "$SETTINGS" >/dev/null 2>&1
UNINSTALL_RC=$?
assert_eq "e-uninstall-exit-0" "0" "$UNINSTALL_RC"
CMD_RESTORED=$(jq -r '.statusLine.command' "$SETTINGS")
assert_eq "e-uninstall-restores-original" "my-original-statusline --foo" "$CMD_RESTORED"
HAS_RECORD=$(jq -r 'has("statusLine") and (.statusLine | has("wowOriginalCommand"))' "$SETTINGS")
assert_eq "e-uninstall-clears-record" "false" "$HAS_RECORD"
rm -rf "$DI"

rm -rf "$FIXTURE_BIN"

echo "statusline-usage-persist: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
