#!/usr/bin/env bash
# Story 140: pin the plan-location migration doctrine across EVERY plan-path
# consumer, so the worktree-rooted-plans contract can't silently revert (a
# doctrine-regression grep — the migration touches 6 role files; this is the
# guard that they stay consistent).
set -u
PASS=0; FAIL=0; FAILED=()
CMD="$(cd "$(dirname "$0")/../commands" && pwd)"
chk(){ local name="$1" file="$2" pat="$3"
  if grep -qE "$pat" "$CMD/$file"; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED+=("$name ($file lacks /$pat/)"); fi; }

# locator contract (the foundation the others reference)
chk "agent-protocol-locator-section" _agent-protocol.md          'Plan-ref resolution'
chk "agent-protocol-slug-derive"     _agent-protocol.md          '\.worktrees/<slug>/<ref>'
# SD producer: draft-in-worktree + catch-up + plan-done guard
chk "sd-draft-in-worktree"           senior-developer.md         'draft the plan \*\*inside the story.s worktree\*\*'
chk "sd-plan-done-guard"             senior-developer.md         'plan-committed-check\.sh'
chk "sd-file-event-worktree-plan"    senior-developer.md         '\.worktrees/<NNN-slug>/implementations/plans/<NNN-slug>\.md'
chk "sd-startup-catchup-worktree"    _senior-developer-startup.md '\.worktrees/<NNN-slug>/implementations/plans'
# PP + T consumers resolve the worktree plan
chk "pp-worktree-plan"               pair-programmer.md          'Plan files live in the worktree'
chk "t-discover-worktree"            tester.md                   'Read the plan from the worktree'
# M sweep made legacy
chk "m-sweep-legacy"                 manager.md                  'legacy / anomaly only'

echo "plan-location-doctrine: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
