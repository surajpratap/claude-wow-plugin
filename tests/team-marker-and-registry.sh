#!/usr/bin/env bash
# Story 150 — team-marker on story/backlog files, registry claim
# idempotency, and worktree-from-branch slug derivation.

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Case 1: team marker on a story file is extractable by grep.
# -----------------------------------------------------------------------------
STORY="$TMP/148-x.md"
cat > "$STORY" <<'EOF'
<!-- status: backlog -->
<!-- team: falcon -->

# Demo story

## Acceptance criteria
- something
EOF
TEAM=$(grep -oE 'team: [a-z0-9-]+' "$STORY" | head -1 | awk '{print $2}')
assert_eq "case-1-team-marker-extract" "falcon" "$TEAM"

# Story status stays line 1 — the team marker is line 2 and does not
# interfere with the existing status extraction.
ST=$(head -1 "$STORY" | grep -oE 'status: [a-z-]+' | awk '{print $2}')
assert_eq "case-1-status-unchanged" "backlog" "$ST"

# -----------------------------------------------------------------------------
# Case 2: registry is valid JSONL and contains no duplicate claimed names.
# -----------------------------------------------------------------------------
REG="$TMP/team_names_repo.jsonl"
cat > "$REG" <<'EOF'
{"name":"falcon","claimed_at":"2026-05-27T11:50:00Z"}
{"name":"eagle","claimed_at":"2026-05-28T09:01:00Z"}
{"name":"otter","claimed_at":"2026-05-28T10:15:00Z"}
EOF
PARSED=$(jq -r '.name' "$REG" 2>/dev/null | wc -l | tr -d ' ')
DUPES=$(jq -r '.name' "$REG" | sort | uniq -d | wc -l | tr -d ' ')
assert_eq "case-2-registry-jsonl-parses" "3" "$PARSED"
assert_eq "case-2-registry-no-duplicates" "0" "$DUPES"

# A registry with a duplicate claim must be detectable.
REG_DUP="$TMP/team_names_repo_dup.jsonl"
cat > "$REG_DUP" <<'EOF'
{"name":"falcon","claimed_at":"2026-05-27T11:50:00Z"}
{"name":"falcon","claimed_at":"2026-05-28T09:01:00Z"}
EOF
DUPES_FOUND=$(jq -r '.name' "$REG_DUP" | sort | uniq -d | wc -l | tr -d ' ')
assert_eq "case-2-duplicate-detectable" "1" "$DUPES_FOUND"

# -----------------------------------------------------------------------------
# Case 3: worktree-from-branch derive drops the team segment.
# Convention: feat/<team>/<NNN>-slug -> .worktrees/<NNN>-slug
#             feat/<NNN>-slug        -> .worktrees/<NNN>-slug (legacy)
# -----------------------------------------------------------------------------
derive_worktree() {
  printf '%s' "$1" | sed -E 's|^feat/([^/]+/)?(.+)$|.worktrees/\2|'
}

assert_eq "case-3-team-worktree-derive" ".worktrees/148-multi-team-and-hygiene" \
  "$(derive_worktree 'feat/falcon/148-multi-team-and-hygiene')"
assert_eq "case-3-legacy-worktree-derive" ".worktrees/067-install-github-app" \
  "$(derive_worktree 'feat/067-install-github-app')"
assert_eq "case-3-team-eagle-derive" ".worktrees/022-home-dir" \
  "$(derive_worktree 'feat/eagle/022-home-dir')"

# -----------------------------------------------------------------------------
# Case 4: backlog file team marker (same convention as story files).
# -----------------------------------------------------------------------------
BL="$TMP/200-foo.md"
cat > "$BL" <<'EOF'
<!-- status: accepted -->
<!-- team: falcon -->
<!-- concern: hygiene -->
<!-- size: small -->

content
EOF
BL_TEAM=$(grep -oE 'team: [a-z0-9-]+' "$BL" | head -1 | awk '{print $2}')
assert_eq "case-4-backlog-team-marker" "falcon" "$BL_TEAM"

echo
echo "team-marker-and-registry: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
