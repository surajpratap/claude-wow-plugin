#!/usr/bin/env bash
# Story 176 — dependency-track-latest routine drift check.
#
# Drives `check-plugin-updates.sh --deps` (the dep-drift surface that extends
# the existing update-coherence path). The policy: plugin.json dependencies
# intentionally track LATEST (no `version` pins); breaking-change risk is
# accepted and mitigated by this mechanical no-pin guard. Cases:
#   1. Real plugin.json: `--deps` lists every declared dependency as
#      `dep <name> <marketplace> tracks-latest`, surfaces the resolved-versions
#      command, exits 0, emits NO `pinned` lines.
#   2. Synthetic pinned plugin.json: `--deps` detects the `.version` pin,
#      emits a `pinned <name> <version>` diagnostic to stderr, exits non-zero.
#
# RED-WITHOUT: patch .red-without/deps-pin-detection.patch -> 2-pinned-nonzero-exit

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
  case "$haystack" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle': '$haystack')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/check-plugin-updates.sh"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"

if [ ! -f "$HELPER" ]; then
  echo "deps-track-latest: SKIP — $HELPER not found"
  exit 0
fi

# ---- (1) real plugin.json: all deps tracks-latest, no pins, exit 0 ----
OUT1=$(bash "$HELPER" --deps "$PLUGIN_JSON" 2>/tmp/deps-err1.$$)
RC1=$?
ERR1=$(cat /tmp/deps-err1.$$ 2>/dev/null); rm -f /tmp/deps-err1.$$
assert_eq "1-real-exit-0" "0" "$RC1"
# Every declared dependency appears as a tracks-latest line.
DECL_COUNT=$(jq -r '.dependencies | length' "$PLUGIN_JSON" 2>/dev/null)
TRACK_COUNT=$(printf '%s\n' "$OUT1" | grep -c 'tracks-latest')
assert_eq "1-real-lists-all-deps" "$DECL_COUNT" "$TRACK_COUNT"
# No pin diagnostics on stdout OR stderr.
PINNED_LINES=$(printf '%s\n%s\n' "$OUT1" "$ERR1" | grep -c '^pinned ')
assert_eq "1-real-no-pinned-lines" "0" "$PINNED_LINES"
# Surfaces the resolved-versions review command.
assert_contains "1-real-surfaces-resolved-cmd" "claude plugin list" "$OUT1"

# ---- (2) synthetic pinned plugin.json: detector fires, non-zero exit ----
D=$(mktemp -d)
PINNED_JSON="$D/plugin.json"
jq '.dependencies[0].version = "1.2.3"' "$PLUGIN_JSON" > "$PINNED_JSON"
OUT2=$(bash "$HELPER" --deps "$PINNED_JSON" 2>/tmp/deps-err2.$$)
RC2=$?
ERR2=$(cat /tmp/deps-err2.$$ 2>/dev/null); rm -f /tmp/deps-err2.$$
assert_eq "2-pinned-nonzero-exit" "1" "$RC2"
PINNED_NAME=$(jq -r '.dependencies[0].name' "$PINNED_JSON")
assert_contains "2-pinned-diagnostic" "pinned $PINNED_NAME 1.2.3" "$ERR2"
rm -rf "$D"

echo "deps-track-latest: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
