#!/usr/bin/env bash
# Story 104 — sprint-finalize.sh: whole-sprint integration→main finalization.
# Covers happy path + dry-run write-free + idempotent + conflict pre-rebase +
# malformed --target + wrong branch.

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
  local name="$1"; local hay="$2"; local needle="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *)
      FAIL=$((FAIL+1))
      FAILED_CASES+=("$name (missing '$needle' in '$hay')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FINALIZE="$PLUGIN_ROOT/scripts/sprint-finalize.sh"

if [ ! -x "$FINALIZE" ]; then
  echo "sprint-finalize-helper: SKIP — $FINALIZE not executable"
  exit 0
fi

# Build a real-git fixture with a bare 'origin' (canonical=main @ v3.24.0)
# and an integration-branch clone holding NEXT-NNN.md placeholders.
# Args: <plugin-version> [extra-files-fn]
mk_git_fixture() {
  local d; d=$(mktemp -d)
  local origin="$d/origin.git" clone="$d/clone"
  git init --bare --quiet "$origin"

  # Seed canonical state in a scratch repo, push to origin.
  local seed="$d/seed"
  git init --quiet "$seed"
  (
    cd "$seed" || exit 99
    git config user.email "t@t.t"; git config user.name "t"
    git config commit.gpgsign false  # test fixture — no signing key to wrangle
    mkdir -p plugin/.claude-plugin plugin/commands \
      plugin/docs/superpowers/migrations/entries plugin/tests
    cat > plugin/.claude-plugin/plugin.json <<EOF
{"name": "x", "version": "3.24.0"}
EOF
    cat > plugin/commands/_manager-startup.md <<EOF
M targets plugin version **\`3.24.0\`** — current target.
EOF
    # Stub pre-flight tests (always succeed).
    cat > plugin/tests/version-coherence.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > plugin/tests/migration-entries-coherence.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x plugin/tests/version-coherence.sh plugin/tests/migration-entries-coherence.sh
    : > plugin/docs/superpowers/migrations/entries/.gitkeep
    git add -A
    git commit -m "seed" --quiet
    git branch -M main
    git remote add origin "$origin"
    git push --quiet origin main
  )

  # Clone, advertise origin/HEAD -> origin/main, create sprint/<id> branch,
  # add 2 NEXT-*.md placeholder entries.
  git clone --quiet "$origin" "$clone" >/dev/null 2>&1
  (
    cd "$clone" || exit 99
    git config user.email "t@t.t"; git config user.name "t"
    git config commit.gpgsign false  # test fixture — no signing key to wrangle
    git remote set-head origin main >/dev/null 2>&1
    git checkout -b sprint/test --quiet
    cat > plugin/docs/superpowers/migrations/entries/NEXT-101.md <<'EOF'
# `<NEXT-from>` → `<NEXT-to>`

Story 101 body line.
EOF
    cat > plugin/docs/superpowers/migrations/entries/NEXT-102.md <<'EOF'
# `<NEXT-from>` → `<NEXT-to>`

Story 102 body line.
EOF
    git add -A
    git commit -m "sprint entries" --quiet
  )

  echo "$d"
}

# (a) Happy path on a real git fixture (resolve + consolidate + stamp + commit).
A_DIR=$(mk_git_fixture)
(
  cd "$A_DIR/clone" || exit 99
  bash "$FINALIZE" --target 3.25.0 >/dev/null 2>&1
  rc=$?
  echo "rc=$rc"
  ls plugin/docs/superpowers/migrations/entries
  echo "---"
  cat plugin/docs/superpowers/migrations/entries/3.25.0.md 2>/dev/null
  echo "---"
  jq -r .version plugin/.claude-plugin/plugin.json
  cat plugin/commands/_manager-startup.md
) > "$A_DIR/out.txt" 2>&1
A_RC=$(grep '^rc=' "$A_DIR/out.txt" | head -1 | sed 's/rc=//')
assert_eq "happy-rc" "0" "$A_RC"
A_BODY=$(cat "$A_DIR/out.txt")
assert_contains "happy-consolidated-exists" "$A_BODY" "3.25.0.md"
assert_contains "happy-no-NEXT-remaining" \
  "$(ls "$A_DIR/clone/plugin/docs/superpowers/migrations/entries/" | grep -c '^NEXT-' || true)" "0"
assert_contains "happy-header" "$A_BODY" "3.24.0"
assert_contains "happy-header2" "$A_BODY" "3.25.0"
assert_contains "happy-story-101-subhead" "$A_BODY" "## 101"
assert_contains "happy-story-102-subhead" "$A_BODY" "## 102"
assert_contains "happy-plugin-json" \
  "$(jq -r .version "$A_DIR/clone/plugin/.claude-plugin/plugin.json")" "3.25.0"
assert_contains "happy-startup-stamp" \
  "$(cat "$A_DIR/clone/plugin/commands/_manager-startup.md")" "M targets plugin version **\`3.25.0\`**"

# (b) Dry-run on a real git fixture — writes NOTHING (no file mutation, no git
# state change, no rebase-in-progress).
B_DIR=$(mk_git_fixture)
(
  cd "$B_DIR/clone" || exit 99
  HEAD_BEFORE=$(git rev-parse HEAD)
  bash "$FINALIZE" --target 3.25.0 --dry-run >/dev/null 2>&1
  rc=$?
  echo "rc=$rc"
  echo "HEAD_BEFORE=$HEAD_BEFORE"
  echo "HEAD_AFTER=$(git rev-parse HEAD)"
  if git diff --quiet && git diff --cached --quiet; then echo "TREE=clean"; else echo "TREE=dirty"; fi
  [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] && echo "REBASE=inprogress" || echo "REBASE=none"
  ls plugin/docs/superpowers/migrations/entries
) > "$B_DIR/out.txt" 2>&1
B_RC=$(grep '^rc=' "$B_DIR/out.txt" | sed 's/rc=//')
B_HEAD_BEFORE=$(grep HEAD_BEFORE "$B_DIR/out.txt" | sed 's/HEAD_BEFORE=//')
B_HEAD_AFTER=$(grep HEAD_AFTER "$B_DIR/out.txt" | sed 's/HEAD_AFTER=//')
B_TREE=$(grep '^TREE=' "$B_DIR/out.txt" | sed 's/TREE=//')
B_REBASE=$(grep '^REBASE=' "$B_DIR/out.txt" | sed 's/REBASE=//')
assert_eq "dryrun-rc" "0" "$B_RC"
assert_eq "dryrun-HEAD-untouched" "$B_HEAD_BEFORE" "$B_HEAD_AFTER"
assert_eq "dryrun-tree-clean" "clean" "$B_TREE"
assert_eq "dryrun-no-rebase-in-progress" "none" "$B_REBASE"
# Both NEXT-*.md placeholders still present, no <target>.md created.
B_ENTRIES=$(ls "$B_DIR/clone/plugin/docs/superpowers/migrations/entries/")
assert_contains "dryrun-NEXT-101-intact" "$B_ENTRIES" "NEXT-101.md"
assert_contains "dryrun-NEXT-102-intact" "$B_ENTRIES" "NEXT-102.md"
case "$B_ENTRIES" in
  *"3.25.0.md"*) FAIL=$((FAIL+1)); FAILED_CASES+=("dryrun-target-md-must-not-exist") ;;
  *) PASS=$((PASS+1)) ;;
esac

# (c) Idempotent — re-run on already-finalized branch is no-op exit 0.
C_DIR=$(mk_git_fixture)
(
  cd "$C_DIR/clone" || exit 99
  bash "$FINALIZE" --target 3.25.0 >/dev/null 2>&1
  bash "$FINALIZE" --target 3.25.0 >/dev/null 2>&1
  echo "rc=$?"
) > "$C_DIR/out.txt" 2>&1
C_RC=$(grep '^rc=' "$C_DIR/out.txt" | sed 's/rc=//')
assert_eq "idempotent-rc" "0" "$C_RC"

# (d) Conflict pre-rebase — origin/main advances with a file the sprint branch
# also touches; rebase fails; helper aborts cleanly leaving no rebase-in-progress.
D_DIR=$(mk_git_fixture)
(
  cd "$D_DIR/seed" || exit 99
  # Advance origin/main with a conflicting change to plugin.json's version.
  jq '.version="3.24.99"' plugin/.claude-plugin/plugin.json > pj.tmp && mv pj.tmp plugin/.claude-plugin/plugin.json
  git commit -am "advance main" --quiet
  git push --quiet origin main
)
(
  cd "$D_DIR/clone" || exit 99
  # Also mutate plugin.json on the sprint branch to force the conflict.
  jq '.version="3.24.50"' plugin/.claude-plugin/plugin.json > pj.tmp && mv pj.tmp plugin/.claude-plugin/plugin.json
  git commit -am "sprint mutation" --quiet
  bash "$FINALIZE" --target 3.25.0 >/dev/null 2>&1
  rc=$?
  echo "rc=$rc"
  [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] && echo "REBASE=inprogress" || echo "REBASE=none"
) > "$D_DIR/out.txt" 2>&1
D_RC=$(grep '^rc=' "$D_DIR/out.txt" | sed 's/rc=//')
D_REBASE=$(grep '^REBASE=' "$D_DIR/out.txt" | sed 's/REBASE=//')
assert_eq "conflict-rc-nonzero" "1" "$D_RC"
assert_eq "conflict-no-rebase-in-progress" "none" "$D_REBASE"

# (e) Malformed --target — exit 2 + usage line.
E_OUT=$(bash "$FINALIZE" --target 9.9 2>&1); E_RC=$?
assert_eq "bad-target-rc" "2" "$E_RC"
assert_contains "bad-target-usage" "$E_OUT" "usage:"

# (f) Missing --target — exit 2.
F_OUT=$(bash "$FINALIZE" --dry-run 2>&1); F_RC=$?
assert_eq "missing-target-rc" "2" "$F_RC"

# (g) Wrong branch — refused on a feat/* branch.
G_DIR=$(mk_git_fixture)
(
  cd "$G_DIR/clone" || exit 99
  git checkout -B feat/whatever --quiet
  bash "$FINALIZE" --target 3.25.0 >/dev/null 2>&1
  echo "rc=$?"
) > "$G_DIR/out.txt" 2>&1
G_RC=$(grep '^rc=' "$G_DIR/out.txt" | sed 's/rc=//')
assert_eq "wrong-branch-rc" "2" "$G_RC"

# (h) Helper-level semver compare — sourced functions work in isolation.
H_RESULT=$(bash -c "source '$FINALIZE'; _semver_cmp 3.25.0 3.24.0")
assert_eq "semver-cmp-gt" "gt" "$H_RESULT"
H2=$(bash -c "source '$FINALIZE'; _semver_cmp 3.24.0 3.24.0")
assert_eq "semver-cmp-eq" "eq" "$H2"
H3=$(bash -c "source '$FINALIZE'; _semver_cmp 3.24.0 3.25.0")
assert_eq "semver-cmp-lt" "lt" "$H3"

# Cleanup.
rm -rf "$A_DIR" "$B_DIR" "$C_DIR" "$D_DIR" "$G_DIR"

echo "sprint-finalize-helper: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
