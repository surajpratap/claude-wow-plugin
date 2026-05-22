#!/usr/bin/env bash
# Story 142 — contract-size-recheck.sh flags multi-role / payload-key /
# artifact-location stories as not-tiny at dispatch.
#
# Validates against the REAL in-repo corpus (stories/backlogs), not synthetic
# fixtures worded to match the regex — that synthetic-fixture trap is the exact
# masking class story 141 + this sprint target. Real ≥medium items must flag;
# inflection + word-boundary edge cases pin the round-1 regex bugs PP caught.

set -u
PASS=0; FAIL=0; FAILED=()
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); FAILED+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/contract-size-recheck.sh"

if [ ! -f "$SCRIPT" ]; then echo "contract-size-recheck: FAIL — $SCRIPT not found" >&2; exit 1; fi

# run <file> -> sets RC (no command-substitution between the call and $?)
RC=0
run(){ bash "$SCRIPT" "$1" >/dev/null 2>&1; RC=$?; }
# run on inline text via a temp file
runtext(){ local t; t=$(mktemp); printf '%s\n' "$1" > "$t"; run "$t"; rm -f "$t"; }

# ---- Real-corpus ≥medium cases (load-bearing: catches REAL wording, not a
#      regex-shaped synthetic fixture). story 140 (multi-role+location), backlog
#      159 (payload field), backlog 161 (orphaned) are genuine migrations. ------
for rel in \
  "implementations/stories/140-sd-commit-plan-files-to-feat-branch.md" \
  "implementations/backlog/159-sprint-pace-surface-unstarted-dispatched.md" \
  "implementations/backlog/161-sd-commit-plan-files-to-feat-branch.md" ; do
  f="$REPO_ROOT/$rel"
  if [ -f "$f" ]; then
    run "$f"
    if [ "$RC" -eq 1 ]; then ok; else bad "real-corpus $rel expected >=medium (exit 1), got $RC"; fi
  fi  # absent (e.g. parked/renamed) is not a failure of the heuristic
done

# ---- Story-only limitation (PP rec 4), pinned on REAL data: the terse sprint
#      story 138 defers its spec to backlog 159, so the STORY text has no signals
#      → exit 0, even though the work is a real payload-field migration (caught
#      via backlog 159 above). This is the documented limitation, not a bug. -----
f138="$REPO_ROOT/implementations/stories/138-sprint-pace-surface-unstarted-dispatched.md"
if [ -f "$f138" ]; then
  run "$f138"
  if [ "$RC" -eq 0 ]; then ok; else bad "story-only-limitation: terse story 138 expected exit 0, got $RC"; fi
fi

# ---- Synthetic tiny baseline (no masking risk here) → exit 0 -----------------
runtext "# Fix a typo in the README. Single one-line doc tweak."
if [ "$RC" -eq 0 ]; then ok; else bad "tiny doc tweak should be exit 0, got $RC"; fi

# ---- Inflection cases (the round-1 regex bug PP caught) → exit 1 -------------
for w in "we relocate the artifact" "relocated the plans" "relocation of files" "files orphaned on main" "a plan-location migration"; do
  runtext "$w"
  if [ "$RC" -eq 1 ]; then ok; else bad "artifact-location inflection '$w' should flag (got $RC)"; fi
done

# ---- Word-boundary guard: 'remove' must NOT fire artifact-location -----------
runtext "remove the dead code; removed the old helper"
if [ "$RC" -eq 0 ]; then ok; else bad "'remove' wrongly flagged artifact-location (got $RC)"; fi

# ---- payload wording variants (round-1 too-tight regex) → exit 1 -------------
runtext "the story-created payload gains a foo field"
if [ "$RC" -eq 1 ]; then ok; else bad "'payload gains a foo field' should flag (got $RC)"; fi
runtext "adds a new field on the story-created payload"
if [ "$RC" -eq 1 ]; then ok; else bad "'field ... payload' should flag (got $RC)"; fi

# ---- multi-role: >=2 commands/*.md → exit 1 ; single role → not multi-role ---
runtext "edits commands/senior-developer.md and commands/pair-programmer.md"
if [ "$RC" -eq 1 ]; then ok; else bad "two role files should flag multi-role (got $RC)"; fi

# ---- usage: missing-file arg → exit 2 ----------------------------------------
run "/no/such/file/xyzzy.md"
if [ "$RC" -eq 2 ]; then ok; else bad "missing file should exit 2 (got $RC)"; fi

echo "contract-size-recheck: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
