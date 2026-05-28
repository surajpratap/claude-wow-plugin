#!/usr/bin/env bash
# Story 150 — branch-name parse extracts NNN from both legacy and team-scoped
# branch shapes: feat/<NNN>-slug and feat/<team>/<NNN>-slug both yield <NNN>.
# The parse pattern lives inline in scripts/sprint-merge-bump.sh; this test
# pins both shapes against the same sed expression the script uses.

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

# Helper mirrors the exact extraction expression sprint-merge-bump.sh runs.
# Single-source-of-truth: if the script's regex changes, this helper must
# track. The shape: an optional team segment ([^/]+/)? then the NNN digits.
extract_story_id() {
  printf '%s' "$1" | sed -E 's|^feat/([^/]+/)?([0-9]+).*|\2|'
}

# Legacy (no team segment)
assert_eq "legacy-feat-148"      "148" "$(extract_story_id 'feat/148-slug')"
assert_eq "legacy-feat-001"      "001" "$(extract_story_id 'feat/001-x')"
assert_eq "legacy-feat-with-dot" "067" "$(extract_story_id 'feat/067-install-github-app-workflow-fixup')"

# Team-scoped (one team segment between feat/ and NNN)
assert_eq "team-falcon-148"   "148" "$(extract_story_id 'feat/falcon/148-multi-team-and-hygiene')"
assert_eq "team-eagle-022"    "022" "$(extract_story_id 'feat/eagle/022-home-dir-convention')"
assert_eq "team-otter-999"    "999" "$(extract_story_id 'feat/otter/999-final-story')"

# The script reads back this value on the live script too — anti-drift guard.
# If sprint-merge-bump.sh diverges from the helper above, the suite fails.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MERGE_SCRIPT="$ROOT/scripts/sprint-merge-bump.sh"

# The script must contain the team-aware sed expression (not the legacy
# 'feat/[0-9]+' grep that fails on feat/<team>/<NNN>).
if grep -qE "sed -E 's\|\^feat/\(\[\^/\]\+/\)\?\(\[0-9\]\+\)\.\*\|.2\|'" "$MERGE_SCRIPT" \
   || grep -qE "\^feat/\(\[\^/\]\+/\)\?\(\[0-9\]\+\)" "$MERGE_SCRIPT"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("script-uses-team-aware-regex (sprint-merge-bump.sh still on legacy 'feat/[0-9]+' regex)")
fi

echo
echo "team-branch-parse: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
