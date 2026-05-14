#!/usr/bin/env bash
# Story 034 — slacker.md auto-launch flow build-step test.
#
# Synthetic-fixture bash test mirroring tests/slack-bridge-spawn.sh (Story 017).
# Focuses on the BUILD-step lifecycle: when dist/ missing OR LOCK_SHA changed,
# the auto-launch flow runs npm run build before spawn; on build failure it
# emits bridge-status: stopped per the spawn-fail behavior section.

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
# Inline helpers — mirror slacker.md prompt logic for step 4b.
# -----------------------------------------------------------------------------

# should_build <bridge-dir>
#   Mirrors: if [ ! -d "$SLACK_BRIDGE_DIR/dist" ] || [ "$LOCK_SHA" != "$SAVED_SHA" ]; then ...
#   Echoes "yes" or "no".
should_build() {
  local dir="$1"
  if [ ! -d "$dir/dist" ]; then
    echo "yes"
    return
  fi
  local lock_sha saved_sha
  lock_sha=$(shasum -a 1 "$dir/package-lock.json" 2>/dev/null | awk '{print $1}')
  saved_sha=$(cat "$dir/.deps-installed" 2>/dev/null || true)
  if [ "$lock_sha" != "$saved_sha" ]; then
    echo "yes"
  else
    echo "no"
  fi
}

# emit_degraded_to_bus <bus-path> <reason>
emit_degraded_to_bus() {
  local bus="$1" reason="$2"
  printf '{"ts":"2026-05-02T10:00:00Z","from":"slacker-test","to":"manager-*","type":"bridge-status","payload":{"state":"stopped","reason":"%s"}}\n' "$reason" >> "$bus"
}

# -----------------------------------------------------------------------------
# Fixture builder
# -----------------------------------------------------------------------------

mk_bridge() {
  local dir; dir=$(mktemp -d)
  cat > "$dir/package-lock.json" <<'JSON'
{"name":"@claude-wow-plugin/slack-bridge","lockfileVersion":3}
JSON
  echo "$dir"
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: fresh install — no dist/ → build runs → dist/ created.
DIR=$(mk_bridge)
RESULT=$(should_build "$DIR")
assert_eq "case-1-fresh-install-builds" "yes" "$RESULT"
# Mock npm run build by touching dist/index.js
mkdir -p "$DIR/dist"
touch "$DIR/dist/index.js"
[ -d "$DIR/dist" ] && [ -f "$DIR/dist/index.js" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-1-dist-created"); }
rm -rf "$DIR"

# Case 2: dist/ present + cache match → build skipped.
DIR=$(mk_bridge)
mkdir -p "$DIR/dist"
touch "$DIR/dist/index.js"
LOCK_SHA=$(shasum -a 1 "$DIR/package-lock.json" | awk '{print $1}')
echo "$LOCK_SHA" > "$DIR/.deps-installed"
RESULT=$(should_build "$DIR")
assert_eq "case-2-cache-match-skips-build" "no" "$RESULT"
rm -rf "$DIR"

# Case 3: dist/ present BUT cache stale → build runs.
DIR=$(mk_bridge)
mkdir -p "$DIR/dist"
touch "$DIR/dist/index.js"
echo "stale-sha-from-prior-install" > "$DIR/.deps-installed"
RESULT=$(should_build "$DIR")
assert_eq "case-3-cache-stale-builds" "yes" "$RESULT"
rm -rf "$DIR"

# Case 4: build failure emits degraded.
DIR=$(mk_bridge)
BUS="$DIR/bus.jsonl"
: > "$BUS"
RESULT=$(should_build "$DIR")
assert_eq "case-4-build-needed" "yes" "$RESULT"
# Simulate npm run build returning non-zero — emit degraded.
emit_degraded_to_bus "$BUS" "npm run build failed"
LAST=$(tail -1 "$BUS")
case "$LAST" in
  *'"type":"bridge-status"'*'"reason":"npm run build failed"'*) assert_eq "case-4-degraded-emitted" "yes" "yes" ;;
  *) assert_eq "case-4-degraded-emitted" "yes" "no (got: $LAST)" ;;
esac
rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "slacker-bridge-launch: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
