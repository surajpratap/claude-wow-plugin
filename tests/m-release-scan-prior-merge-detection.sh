#!/usr/bin/env bash
# Story 064 — regression test for scripts/m-prior-merge-detect.sh.
#
# Per Story 064 AC #4. Each case sets up a temporary git repo with fake
# merge commits + a story file; invokes the helper; asserts on the
# stdout output line.
#
# Cases:
#   1. Clear MATCH — feat(NNN) merge subject → MATCH stdout
#   2. NONE — no story-id references → NONE stdout
#   3. AMBIGUOUS — (#N) merge whose PR head was feat/<NNN>-* → AMBIGUOUS
#      stdout (PATH-overridden gh shim returns canned headRefName)
#   4. Idempotency — running twice on a fresh repo gives the same answer
#   5. Tier-1-only fallback — gh missing → AMBIGUOUS path skipped, NONE

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/m-prior-merge-detect.sh"

PASS=0
FAIL=0
FAILED_CASES=()

assert_starts_with() {
  local name="$1"; local prefix="$2"; local actual="$3"
  case "$actual" in
    "$prefix"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (expected prefix '$prefix', got '$actual')") ;;
  esac
}

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

# Build a fresh tmp repo with N seed commits on main, then return its path.
# Caller adds story-specific commits + invokes the helper.
mk_repo() {
  local d
  d=$(mktemp -d)
  (
    cd "$d" || exit 1
    git init -q -b main 2>/dev/null || git init -q
    git checkout -q -b main 2>/dev/null || true
    git config user.email "test@example.com"
    git config user.name "test"
    echo "seed" > README
    git add README
    git commit -q -m "initial commit"
  )
  echo "$d"
}

# -----------------------------------------------------------------------------
# Case 1: Clear MATCH — feat(NNN) merge subject
# -----------------------------------------------------------------------------
P1=$(mk_repo)
(
  cd "$P1" || exit 1
  git commit -q --allow-empty -m "feat(053): subshell-PPID trap learning entry (#50)"
)
OUT1=$(bash "$HELPER" 053 subshell-ppid-trap-learning "$P1" 2>/dev/null)
assert_starts_with "case-1-clear-match-prefix" "MATCH " "$OUT1"
case "$OUT1" in
  *"feat(053)"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); FAILED_CASES+=("case-1-clear-match-subject (got '$OUT1')") ;;
esac
rm -rf "$P1"

# -----------------------------------------------------------------------------
# Case 2: NONE — no story-id references
# -----------------------------------------------------------------------------
P2=$(mk_repo)
(
  cd "$P2" || exit 1
  git commit -q --allow-empty -m "chore: unrelated cleanup"
  git commit -q --allow-empty -m "fix: typo in README"
)
OUT2=$(bash "$HELPER" 999 nonexistent-story "$P2" 2>/dev/null)
assert_eq "case-2-no-match-none" "NONE" "$OUT2"
rm -rf "$P2"

# -----------------------------------------------------------------------------
# Case 3: AMBIGUOUS — (#N) merge whose PR head was feat/<NNN>-* (gh shim)
# -----------------------------------------------------------------------------
P3=$(mk_repo)
(
  cd "$P3" || exit 1
  # Subject doesn't reference story id directly, but does have (#42).
  git commit -q --allow-empty -m "Some random impl thing (#42)"
)
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
# Stub `gh pr view <num> --json headRefName --jq '.headRefName'`
# Returns the feat-branch name encoding both story id + slug.
case "$*" in
  *"pr view 42"*) echo "feat/064-m-stale-status-re-release-detection" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIM_DIR/gh"
OUT3=$(PATH="$SHIM_DIR:$PATH" bash "$HELPER" 064 m-stale-status-re-release-detection "$P3" 2>/dev/null)
assert_starts_with "case-3-ambiguous-prefix" "AMBIGUOUS " "$OUT3"
case "$OUT3" in
  *" 42 "*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); FAILED_CASES+=("case-3-ambiguous-pr-num (got '$OUT3')") ;;
esac
rm -rf "$P3" "$SHIM_DIR"

# -----------------------------------------------------------------------------
# Case 4: Idempotency — running twice on the same repo gives the same answer
# -----------------------------------------------------------------------------
P4=$(mk_repo)
(
  cd "$P4" || exit 1
  git commit -q --allow-empty -m "feat(064): m release-scan prior-merge detection (#62)"
)
OUT4A=$(bash "$HELPER" 064 m-stale-status-re-release-detection "$P4" 2>/dev/null)
OUT4B=$(bash "$HELPER" 064 m-stale-status-re-release-detection "$P4" 2>/dev/null)
assert_eq "case-4-idempotent" "$OUT4A" "$OUT4B"
assert_starts_with "case-4-still-match" "MATCH " "$OUT4A"
rm -rf "$P4"

# -----------------------------------------------------------------------------
# Case 5: Tier-1-only fallback — gh missing → AMBIGUOUS arm skipped → NONE
# -----------------------------------------------------------------------------
P5=$(mk_repo)
(
  cd "$P5" || exit 1
  # Has (#N) merge but no story-id reference; only Tier-2 could MATCH.
  git commit -q --allow-empty -m "Some impl (#99)"
)
# Build a PATH that has git/grep/etc. but NOT gh — point to a clean tmp dir
# first, so `command -v gh` returns false. Use system util dirs only.
EMPTY_PATH_DIR=$(mktemp -d)
GIT_BIN_DIR="$(dirname "$(command -v git)")"
OUT5=$(PATH="$EMPTY_PATH_DIR:$GIT_BIN_DIR:/usr/bin:/bin" bash "$HELPER" 064 m-stale-status-re-release-detection "$P5" 2>/dev/null)
assert_eq "case-5-no-gh-fallback-none" "NONE" "$OUT5"
rm -rf "$P5" "$EMPTY_PATH_DIR"

echo "m-release-scan-prior-merge-detection: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
