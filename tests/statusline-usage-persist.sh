#!/usr/bin/env bash
# Story 172 + 175 — config-dir usage-statusline snapshot installer
# `statusline-usage-persist.sh`.
#
# Story 175 reworks install from a self-referential env-var-delegating wrapper
# (broken: the render path read $WOW_STATUSLINE_ORIGINAL_CMD which nothing set,
# and the install target was an unscoped path that could land in a PROJECT
# .claude) into: the script resolves the CONFIG-DIR target itself
# (${CLAUDE_CONFIG_DIR:-$HOME/.claude}) and generates a self-contained snapshot
# script that inlines the persist logic AND the captured original command.
#
# Cases (one block per Story-175 AC):
#   1. config-dir resolution (AC1): --install with NO path arg resolves to
#      $CLAUDE_CONFIG_DIR/settings.json and never writes a project .claude;
#      --install with a path OUTSIDE the config dir is refused (non-zero + stderr).
#   2. snapshot delegate (AC2): the generated script pipes stdin to the captured
#      original; stdout + exit pass through unchanged; state file written.
#   3a. empty-original no-blank / repair (AC3-i): --uninstall of a WOW install
#       that recorded an EMPTY original removes the .statusLine block entirely
#       (no blank wrapper left behind).
#   3b. fresh empty-ORIG (AC3-ii): --install when config dir has NO prior
#       statusline → generated script renders nothing (== unset, per CC docs)
#       AND still persists.
#   4. project repair (AC4): config-dir --install detects + uninstalls a prior
#      buggy install in the PROJECT .claude/settings.json.
#   5. uninstall restore + idempotent re-install (AC5).
#
# RED-WITHOUT: patch .red-without/out-of-config-refusal.patch -> 1c-refuse-outside-config
# RED-WITHOUT: patch .red-without/delegate-passthrough.patch -> 2-delegate-stdout
# RED-WITHOUT: patch .red-without/uninstall-empty-block.patch -> 3a-empty-block-removed
# RED-WITHOUT: patch .red-without/fresh-empty-render.patch -> 3b-fresh-renders-nothing
# RED-WITHOUT: patch .red-without/project-repair-sweep.patch -> 4-project-restored
# RED-WITHOUT: patch .red-without/idempotent-reinstall.patch -> 5-idempotent-preserves-original
# RED-WITHOUT: patch .red-without/uninstall-restore.patch -> 5-uninstall-restores

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

GEN_BASENAME="wow-usage-statusline.sh"

# A fixture original statusline command: writes the bytes it received to $SEEN,
# prints a marker, exits 7 — so we can assert stdin + stdout + exit passthrough.
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

RATE_JSON='{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":"2026-05-31T18:00:00Z"},"seven_day":{"used_percentage":11,"resets_at":"2026-06-05T00:00:00Z"}},"other":"x"}'

# ============================================================================
# (1) config-dir resolution (AC1)
# ============================================================================
CFG=$(mktemp -d); PROJ=$(mktemp -d)
mkdir -p "$PROJ/.claude"
echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"$ORIG_CMD\"}}" > "$CFG/settings.json"
# no project statusline pre-exists
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" bash "$WRAPPER" --install >/dev/null 2>&1
RC=$?
assert_eq "1a-install-exit-0" "0" "$RC"
CMD_AFTER=$(jq -r '.statusLine.command' "$CFG/settings.json" 2>/dev/null)
case "$CMD_AFTER" in
  *"$GEN_BASENAME") assert_eq "1a-config-points-to-generated" "yes" "yes" ;;
  *) assert_eq "1a-config-points-to-generated" "yes" "no ($CMD_AFTER)" ;;
esac
assert_eq "1a-generated-script-exists" "yes" "$([ -f "$CFG/$GEN_BASENAME" ] && echo yes || echo no)"
# A project .claude/settings.json was never created.
assert_eq "1b-project-untouched" "absent" "$([ -e "$PROJ/.claude/settings.json" ] && echo present || echo absent)"
# --install with a path OUTSIDE the config dir is refused.
OUTSIDE="$PROJ/.claude/settings.json"
echo '{"statusLine":{"type":"command","command":"user-proj-line"}}' > "$OUTSIDE"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" bash "$WRAPPER" --install "$OUTSIDE" >/dev/null 2>"$CFG/err.txt"
RC_REF=$?
assert_eq "1c-refuse-outside-config" "nonzero" "$([ "$RC_REF" -ne 0 ] && echo nonzero || echo zero)"
assert_eq "1c-refuse-diagnostic" "yes" "$([ -s "$CFG/err.txt" ] && echo yes || echo no)"
# The outside file was NOT converted into a WOW install.
OUT_CMD=$(jq -r '.statusLine.command' "$OUTSIDE" 2>/dev/null)
assert_eq "1c-outside-not-installed" "user-proj-line" "$OUT_CMD"
rm -rf "$CFG" "$PROJ"

# ============================================================================
# (2) snapshot delegate passthrough (AC2)
# ============================================================================
CFG=$(mktemp -d); PROJ=$(mktemp -d); STATE="$CFG/state.json"
echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"$ORIG_CMD\"}}" > "$CFG/settings.json"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" bash "$WRAPPER" --install >/dev/null 2>&1
GEN="$CFG/$GEN_BASENAME"
OUT=$(printf '%s\n' "$RATE_JSON" | WOW_USAGE_STATE_FILE="$STATE" bash "$GEN")
RC=$?
assert_eq "2-delegate-exit" "7" "$RC"
assert_eq "2-delegate-stdout" "ORIGINAL-STATUSLINE-RENDER" "$OUT"
assert_eq "2-delegate-stdin-content" "42" "$(jq -r '.rate_limits.five_hour.used_percentage' < "$SEEN" 2>/dev/null)"
assert_eq "2-persist-five-pct" "42" "$(jq -r '.five_hour.used_percentage' "$STATE" 2>/dev/null)"
assert_eq "2-persist-has-ts" "true" "$(jq -r 'has("captured_ts")' "$STATE" 2>/dev/null)"
rm -rf "$CFG" "$PROJ"

# ============================================================================
# (3a) empty-original no-blank repair via uninstall (AC3-i)
# ============================================================================
CFG=$(mktemp -d)
# old-bug shape: command points at a WOW wrapper, recorded original is EMPTY.
cat > "$CFG/settings.json" <<EOF
{"statusLine":{"type":"command","command":"/some/old/statusline-usage-persist.sh","wowOriginalCommand":""}}
EOF
touch "$CFG/$GEN_BASENAME"
CLAUDE_CONFIG_DIR="$CFG" bash "$WRAPPER" --uninstall >/dev/null 2>&1
# The .statusLine block is removed entirely (NOT left as a blank wrapper).
HAS_SL=$(jq -r 'has("statusLine")' "$CFG/settings.json" 2>/dev/null)
assert_eq "3a-empty-block-removed" "false" "$HAS_SL"
rm -rf "$CFG"

# ============================================================================
# (3b) fresh empty-ORIG renders nothing + still persists (AC3-ii)
# ============================================================================
CFG=$(mktemp -d); PROJ=$(mktemp -d); STATE="$CFG/state.json"
echo '{}' > "$CFG/settings.json"   # no prior statusline
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" bash "$WRAPPER" --install >/dev/null 2>&1
GEN="$CFG/$GEN_BASENAME"
assert_eq "3b-fresh-generated-exists" "yes" "$([ -f "$GEN" ] && echo yes || echo no)"
OUT=$(printf '%s\n' "$RATE_JSON" | WOW_USAGE_STATE_FILE="$STATE" bash "$GEN")
RC=$?
assert_eq "3b-fresh-renders-nothing" "" "$OUT"
assert_eq "3b-fresh-exit-0" "0" "$RC"
assert_eq "3b-fresh-still-persists" "42" "$(jq -r '.five_hour.used_percentage' "$STATE" 2>/dev/null)"
rm -rf "$CFG" "$PROJ"

# ============================================================================
# (4) project repair sweep (AC4)
# ============================================================================
CFG=$(mktemp -d); PROJ=$(mktemp -d); mkdir -p "$PROJ/.claude"
echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"$ORIG_CMD\"}}" > "$CFG/settings.json"
# A prior buggy install in the PROJECT, with a recoverable recorded original.
cat > "$PROJ/.claude/settings.json" <<EOF
{"statusLine":{"type":"command","command":"/x/statusline-usage-persist.sh","wowOriginalCommand":"proj-real-line"}}
EOF
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" bash "$WRAPPER" --install >/dev/null 2>&1
PROJ_CMD=$(jq -r '.statusLine.command' "$PROJ/.claude/settings.json" 2>/dev/null)
assert_eq "4-project-restored" "proj-real-line" "$PROJ_CMD"
PROJ_HAS_REC=$(jq -r '.statusLine | has("wowOriginalCommand")' "$PROJ/.claude/settings.json" 2>/dev/null)
assert_eq "4-project-record-cleared" "false" "$PROJ_HAS_REC"
rm -rf "$CFG" "$PROJ"

# ============================================================================
# (5) uninstall restore + idempotent re-install (AC5)
# ============================================================================
CFG=$(mktemp -d); PROJ=$(mktemp -d)
echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"$ORIG_CMD\"}}" > "$CFG/settings.json"
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" bash "$WRAPPER" --install >/dev/null 2>&1
REC1=$(jq -r '.statusLine.wowOriginalCommand // empty' "$CFG/settings.json")
assert_eq "5-records-original" "$ORIG_CMD" "$REC1"
# Idempotent: second install when our generated script is already active is a
# no-op — the recorded original is NOT clobbered with the generated path.
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" bash "$WRAPPER" --install >/dev/null 2>&1
REC2=$(jq -r '.statusLine.wowOriginalCommand // empty' "$CFG/settings.json")
assert_eq "5-idempotent-preserves-original" "$ORIG_CMD" "$REC2"
# Uninstall restores the original command + removes the generated script.
CLAUDE_CONFIG_DIR="$CFG" bash "$WRAPPER" --uninstall >/dev/null 2>&1
RESTORED=$(jq -r '.statusLine.command' "$CFG/settings.json")
assert_eq "5-uninstall-restores" "$ORIG_CMD" "$RESTORED"
assert_eq "5-uninstall-clears-record" "false" "$(jq -r '.statusLine | has("wowOriginalCommand")' "$CFG/settings.json")"
assert_eq "5-uninstall-removes-generated" "absent" "$([ -e "$CFG/$GEN_BASENAME" ] && echo present || echo absent)"
rm -rf "$CFG" "$PROJ"

rm -rf "$FIXTURE_BIN"

echo "statusline-usage-persist: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
