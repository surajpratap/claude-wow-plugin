#!/usr/bin/env bash
# Story 140 — plan-committed-check guard, exercised on temp git repos.
# Proves: tracked+clean+feat/* passes; untracked / dirty / staged-only / on-main /
# detached-HEAD fail; usage/missing → exit 2. Red-green: the SAME clean tracked
# plan on a NON-feat branch fails (the feat-branch arm is load-bearing).
set -u
PASS=0; FAIL=0; FAILED=()
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); FAILED+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$SCRIPT_DIR/../scripts/plan-committed-check.sh"
[ -f "$GUARD" ] || { echo "plan-committed-check: SKIP — guard not found"; exit 0; }

# init a temp repo on feat/x with a committed plan; echo its path
mkrepo(){
  local d; d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  mkdir -p "$d/implementations/plans"
  echo base > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm baseline
  git -C "$d" checkout -q -b feat/x
  printf '%s' "$d"
}
expect(){ local p="$1" want="$2" name="$3" rc=0; bash "$GUARD" "$p" >/dev/null 2>&1 || rc=$?; if [ "$rc" -eq "$want" ]; then ok; else bad "$name (want $want, got $rc)"; fi; }

PLAN=implementations/plans/200-x.md

# tracked + clean + feat/* → 0
d=$(mkrepo); echo "plan" > "$d/$PLAN"; git -C "$d" add -A; git -C "$d" commit -qm add-plan
expect "$d/$PLAN" 0 "tracked-clean-feat passes"; rm -rf "$d"

# untracked (created, not added) → 1
d=$(mkrepo); echo "plan" > "$d/$PLAN"
expect "$d/$PLAN" 1 "untracked fails"; rm -rf "$d"

# tracked but modified vs HEAD → 1
d=$(mkrepo); echo "plan" > "$d/$PLAN"; git -C "$d" add -A; git -C "$d" commit -qm add-plan
echo "edit" >> "$d/$PLAN"
expect "$d/$PLAN" 1 "modified-vs-HEAD fails"; rm -rf "$d"

# staged but not committed → 1 (differs from HEAD)
d=$(mkrepo); echo "plan" > "$d/$PLAN"; git -C "$d" add "$PLAN"
expect "$d/$PLAN" 1 "staged-not-committed fails"; rm -rf "$d"

# committed clean but on MAIN (not feat/*) → 1 (red-green: same clean plan, wrong branch)
d=$(mkrepo); echo "plan" > "$d/$PLAN"; git -C "$d" add -A; git -C "$d" commit -qm add-plan
git -C "$d" checkout -q main; git -C "$d" merge -q feat/x
expect "$d/$PLAN" 1 "on-main fails (feat-branch arm load-bearing)"; rm -rf "$d"

# committed clean but DETACHED HEAD → 1
d=$(mkrepo); echo "plan" > "$d/$PLAN"; git -C "$d" add -A; git -C "$d" commit -qm add-plan
git -C "$d" checkout -q --detach HEAD
expect "$d/$PLAN" 1 "detached-HEAD fails"; rm -rf "$d"

# missing arg → 2
rc=0; bash "$GUARD" >/dev/null 2>&1 || rc=$?; if [ "$rc" -eq 2 ]; then ok; else bad "missing-arg → 2 (got $rc)"; fi

# missing file → 2
d=$(mkrepo); expect "$d/implementations/plans/nope.md" 2 "missing-file → 2"; rm -rf "$d"

echo "plan-committed-check: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
