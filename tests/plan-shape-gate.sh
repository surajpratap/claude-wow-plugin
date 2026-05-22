#!/usr/bin/env bash
# Story 147 — diff-scoped plan-shape gate, exercised on temp git repos.
# Proves: a MODIFIED section-less plan fails; a predating UNMODIFIED one is
# ignored (diff-scoping — the key AC); drafts exempt; multi-commit-no-remote
# branches aren't under-scoped; deleted plans don't false-fail (--diff-filter=AM).
set -u
PASS=0; FAIL=0; FAILED=()
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); FAILED+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../scripts/plan-shape-gate.sh"
[ -f "$GATE" ] || { echo "plan-shape-gate: SKIP — gate not found"; exit 0; }

GOOD_PLAN="<!-- status: in-review -->

# P

## AC count
Story AC items: 1. Addressed below."
BAD_PLAN="<!-- status: in-review -->

# P

## Context
no ac count section here."
DRAFT_PLAN="<!-- status: drafting -->

# P
no ac count but it is a draft (exempt)."

# init a temp repo with a baseline commit on 'main'; echo its path
mkrepo(){
  local d; d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  mkdir -p "$d/implementations/plans"
  echo "baseline" > "$d/README.md"
  git -C "$d" add -A; git -C "$d" commit -qm baseline
  printf '%s' "$d"
}
# run the gate against repo $1, assert exit code == $2 (SC-clean: no inline $?).
expect_gate(){ local d="$1" want="$2" name="$3" rc=0; bash "$GATE" "$d" >/dev/null 2>&1 || rc=$?; if [ "$rc" -eq "$want" ]; then ok; else bad "$name (want $want, got $rc)"; fi; }

# (a) branch MODIFIES/adds a section-less plan → exit 1
d=$(mkrepo); git -C "$d" checkout -q -b feat/x
printf '%s\n' "$BAD_PLAN" > "$d/implementations/plans/200-x.md"
git -C "$d" add -A; git -C "$d" commit -qm add-bad
expect_gate "$d" 1 "a: section-less modified plan should fail"
rm -rf "$d"

# (b) branch adds a plan WITH the section → exit 0
d=$(mkrepo); git -C "$d" checkout -q -b feat/x
printf '%s\n' "$GOOD_PLAN" > "$d/implementations/plans/201-x.md"
git -C "$d" add -A; git -C "$d" commit -qm add-good
expect_gate "$d" 0 "b: plan with section should pass"
rm -rf "$d"

# (c) a PREDATING section-less plan exists on main, branch leaves it UNMODIFIED → ignored (exit 0)
d=$(mkrepo)
printf '%s\n' "$BAD_PLAN" > "$d/implementations/plans/050-legacy.md"   # legacy, on main
git -C "$d" add -A; git -C "$d" commit -qm legacy
git -C "$d" checkout -q -b feat/x
echo "unrelated" > "$d/src.txt"; git -C "$d" add -A; git -C "$d" commit -qm unrelated
expect_gate "$d" 0 "c: predating UNMODIFIED section-less plan must be ignored (diff-scope)"
rm -rf "$d"

# (d) branch adds a DRAFT plan missing the section → exempt → exit 0
d=$(mkrepo); git -C "$d" checkout -q -b feat/x
printf '%s\n' "$DRAFT_PLAN" > "$d/implementations/plans/202-x.md"
git -C "$d" add -A; git -C "$d" commit -qm add-draft
expect_gate "$d" 0 "d: draft plan exempt"
rm -rf "$d"

# (f) multi-commit branch, NO remote: section-less plan added in commit 1 of 3 → still gated (exit 1)
d=$(mkrepo); git -C "$d" checkout -q -b feat/x
printf '%s\n' "$BAD_PLAN" > "$d/implementations/plans/203-x.md"; git -C "$d" add -A; git -C "$d" commit -qm c1
echo a > "$d/a"; git -C "$d" add -A; git -C "$d" commit -qm c2
echo b > "$d/b"; git -C "$d" add -A; git -C "$d" commit -qm c3
expect_gate "$d" 1 "f: multi-commit branch (no remote) must catch the commit-1 plan via local-main merge-base"
rm -rf "$d"

# (g) branch DELETES a plan → --diff-filter=AM skips it → no "file not found" false-fail (exit 0)
d=$(mkrepo)
printf '%s\n' "$GOOD_PLAN" > "$d/implementations/plans/204-x.md"; git -C "$d" add -A; git -C "$d" commit -qm add
git -C "$d" checkout -q -b feat/x
git -C "$d" rm -q "implementations/plans/204-x.md"; git -C "$d" commit -qm del
expect_gate "$d" 0 "g: deleted plan must not false-fail (--diff-filter=AM)"
rm -rf "$d"

echo "plan-shape-gate: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
