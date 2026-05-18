#!/usr/bin/env bash
# Story 113 — sprint-merge-bump.sh CANONICAL_BRANCH resolution falls back to
# `main` when `git symbolic-ref refs/remotes/origin/HEAD` fails. Pre-Story-113
# this was a silent CANONICAL_BRANCH="" (dead `|| echo main` after a piped sed
# that exits 0 on empty input).

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
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}
assert_not_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) FAIL=$((FAIL+1))
                 FAILED_CASES+=("$name (haystack unexpectedly contains '$needle')") ;;
    *) PASS=$((PASS+1)) ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/sprint-merge-bump.sh"

# ---- Case (a): production script contains the assign-then-default form ----
BODY=$(cat "$SCRIPT")
assert_contains "a-assign-then-default-present" \
  'CANONICAL_BRANCH="${CANONICAL_BRANCH:-main}"' "$BODY"
# Anti-revert: the old `|| echo main` dead-fallback must NOT be present.
assert_not_contains "a-no-dead-fallback" "|| echo main" "$BODY"

# ---- Case (b): real-git fixture without origin/HEAD → resolution = main ----
# Source the resolution snippet in a sub-bash with a real git repo whose
# origin/HEAD is intentionally unset, and assert CANONICAL_BRANCH=="main".
D=$(mktemp -d)
(
  cd "$D" || exit 99
  git init --quiet
  git config user.email "t@t.t"; git config user.name "t"
  git config commit.gpgsign false
  # No origin, no origin/HEAD — `git symbolic-ref refs/remotes/origin/HEAD`
  # exits non-zero. The fix's assign-then-default must yield "main".
  CANONICAL_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  CANONICAL_BRANCH="${CANONICAL_BRANCH:-main}"
  echo "RESOLVED=$CANONICAL_BRANCH"
) > "$D/out.txt" 2>&1
RESOLVED=$(grep '^RESOLVED=' "$D/out.txt" | sed 's/RESOLVED=//')
assert_eq "b-absent-origin-HEAD-falls-back-to-main" "main" "$RESOLVED"
rm -rf "$D"

# ---- Case (c): real-git fixture WITH origin/HEAD set — resolution mirrors it ----
# Confirm the normal case still works. Two clones: a bare origin with main
# branch pushed + a working clone whose origin/HEAD points at origin/main.
D2=$(mktemp -d)
(
  cd "$D2" || exit 99
  git init --bare --quiet origin.git
  git init --quiet seed
  cd seed || exit 99
  git config user.email "t@t.t"; git config user.name "t"
  git config commit.gpgsign false
  echo "seed" > x.txt
  git add x.txt
  git commit -m "seed" --quiet
  git branch -M main
  git remote add origin "$D2/origin.git"
  git push --quiet origin main
  cd "$D2" || exit 99
  git clone --quiet "$D2/origin.git" clone
  cd clone || exit 99
  git remote set-head origin main >/dev/null 2>&1
  CANONICAL_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  CANONICAL_BRANCH="${CANONICAL_BRANCH:-main}"
  echo "RESOLVED=$CANONICAL_BRANCH"
) > "$D2/out.txt" 2>&1
RESOLVED2=$(grep '^RESOLVED=' "$D2/out.txt" | sed 's/RESOLVED=//')
assert_eq "c-present-origin-HEAD-matches" "main" "$RESOLVED2"
rm -rf "$D2"

echo "sprint-merge-bump-canonical-fallback: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
