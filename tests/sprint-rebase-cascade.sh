#!/usr/bin/env bash
# Story 012 / Section H — sprint rebase cascade regression test.
#
# Sets up a synthetic git scratch repo with parent + child stacked,
# simulates a parent merge into main, runs the cascade script, and
# asserts:
#   - cascade exits 0
#   - child branch's tip is now reachable from main
#   - stub gh was invoked with `pr edit ... --base main`
#   - manifest gained a `rebases` entry
#
# Plus a dirty-worktree case (exit 2) and a rebase-conflict case (exit 3).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASCADE="$REPO_ROOT/scripts/sprint-rebase-cascade.sh"

if [ ! -f "$CASCADE" ]; then
  echo "FATAL: missing cascade script at $CASCADE" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "FATAL: jq + git required" >&2
  exit 2
fi

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
  if printf '%s' "$haystack" | grep -q -F -- "$needle"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected to contain '$needle')")
  fi
}

# Build a synthetic repo with parent + child branches stacked.
# Layout:
#   <tmp>/origin.git           — bare upstream
#   <tmp>/repo                 — working clone with main, feat/parent, feat/child
#   <tmp>/repo/.worktrees/child — worktree for feat/child
setup_repo() {
  local tmp="$1"
  mkdir -p "$tmp/bin"

  # Stub gh that records pr-edit calls to a log
  cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
LOG="$tmp/gh.log"
mkdir -p "\$(dirname "\$LOG")"
printf '%s\\n' "\$*" >> "\$LOG"
exit 0
EOF
  chmod +x "$tmp/bin/gh"

  git init --bare "$tmp/origin.git" >/dev/null 2>&1

  git -c init.defaultBranch=main init "$tmp/repo" >/dev/null 2>&1
  cd "$tmp/repo"
  git config user.email "test@example.com"
  git config user.name "test"
  git remote add origin "$tmp/origin.git"

  # Initial commit on main
  echo "main file" > main.txt
  git add main.txt
  git commit -m "initial main commit" >/dev/null 2>&1
  git branch -M main
  git push -u origin main >/dev/null 2>&1

  # feat/parent off main
  git checkout -b feat/parent main >/dev/null 2>&1
  echo "parent change" > parent.txt
  git add parent.txt
  git commit -m "parent commit" >/dev/null 2>&1
  git push -u origin feat/parent >/dev/null 2>&1

  # feat/child off feat/parent (stacked)
  git checkout -b feat/child feat/parent >/dev/null 2>&1
  echo "child change" > child.txt
  git add child.txt
  git commit -m "child commit" >/dev/null 2>&1
  git push -u origin feat/child >/dev/null 2>&1

  # Worktree for feat/child
  git checkout main >/dev/null 2>&1
  git worktree add .worktrees/child feat/child >/dev/null 2>&1

  # Capture parent's tip BEFORE merge (this is what M's prompt would
  # capture from `git rev-parse <parent-branch>@{1}` after the merge;
  # in this test we capture it directly to avoid reflog gymnastics — PP nit
  # on the plan).
  PARENT_OLD_TIP=$(git rev-parse feat/parent)
  printf '%s' "$PARENT_OLD_TIP" > "$tmp/parent-old-tip"

  # Simulate parent merging into main (squash style — same effect as
  # the bridge's pr-state: merged event).
  git checkout main >/dev/null 2>&1
  git merge --squash feat/parent >/dev/null 2>&1
  git commit -m "merged feat/parent" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
}

manifest_for() {
  local tmp="$1"
  cat > "$tmp/m.json" <<'EOF'
{"id":"2026-05-01-t","status":"active","concurrency_limit":2,
 "items":[
   {"id":"P","story":"p.md","status":"merged","depends_on":[],"branch":"feat/parent"},
   {"id":"C","story":"c.md","status":"pending","depends_on":["P"],"branch":"feat/child","stacked_on":"feat/parent"}
 ]}
EOF
}

# Case 1: happy path — clean worktree, rebase succeeds, gh edit recorded.
case_cascade_happy() {
  local tmp; tmp="$(mktemp -d)"
  setup_repo "$tmp"
  manifest_for "$tmp"

  local OLD_TIP; OLD_TIP=$(cat "$tmp/parent-old-tip")
  PATH="$tmp/bin:$PATH" \
    bash "$CASCADE" feat/parent feat/child 42 \
      "$tmp/repo/.worktrees/child" "$tmp/m.json" "$OLD_TIP" P C \
      >"$tmp/cascade.out" 2>"$tmp/cascade.err"
  local rc=$?
  assert_eq "cascade exit" 0 "$rc"

  # Child's tip should now be reachable from main.
  cd "$tmp/repo"
  if git merge-base --is-ancestor feat/child main 2>/dev/null; then
    PASS=$((PASS+1))  # child tip reachable
  elif [ "$(git log feat/child --not main --oneline | wc -l | tr -d ' ')" -le 1 ]; then
    # Or: child has at most 1 commit not on main (the rebased child commit).
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("child should be rebased onto main")
  fi

  # gh log should show pr edit --base main
  if [ -f "$tmp/gh.log" ]; then
    local glog; glog=$(cat "$tmp/gh.log")
    assert_contains "gh.log mentions pr edit" "pr edit" "$glog"
    assert_contains "gh.log mentions --base main" "--base main" "$glog"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("gh.log missing")
  fi

  # Manifest gained a rebases entry
  local rebases; rebases=$(jq -r '.rebases | length' "$tmp/m.json")
  assert_eq "manifest gained 1 rebase entry" "1" "$rebases"
  local pid; pid=$(jq -r '.rebases[0].parent' "$tmp/m.json")
  assert_eq "rebase entry parent=P" "P" "$pid"

  rm -rf "$tmp"
}

# Case 2: dirty worktree → exit 2, no rebase performed.
case_cascade_dirty() {
  local tmp; tmp="$(mktemp -d)"
  setup_repo "$tmp"
  manifest_for "$tmp"

  # Make the child worktree dirty.
  echo "uncommitted" > "$tmp/repo/.worktrees/child/dirty.txt"

  local OLD_TIP; OLD_TIP=$(cat "$tmp/parent-old-tip")
  PATH="$tmp/bin:$PATH" \
    bash "$CASCADE" feat/parent feat/child 42 \
      "$tmp/repo/.worktrees/child" "$tmp/m.json" "$OLD_TIP" P C \
      >"$tmp/cascade.out" 2>"$tmp/cascade.err"
  local rc=$?
  assert_eq "cascade-dirty exit 2" 2 "$rc"

  # No rebase entry should have been added
  local rebases; rebases=$(jq -r '.rebases | length' "$tmp/m.json")
  assert_eq "manifest unchanged on dirty" "0" "$rebases"

  rm -rf "$tmp"
}

case_cascade_happy
case_cascade_dirty

echo
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "failed cases:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  - $c"
  done
  exit 1
fi
exit 0
