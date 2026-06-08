#!/usr/bin/env bash
# Story 147: diff-scoped auto-gate for plan-shape-check.sh (139's `## AC count` lint).
# Runs the lint on ONLY the plan files MODIFIED on the current branch (vs the
# merge-base), so a missing `## AC count` is caught automatically (wired into
# run-all) without anyone remembering to run it. Diff-scoping sidesteps predating
# plans (057/135 …) that lack the section — a blanket scan-all gate is non-viable.
#
#   plan-shape-gate.sh [<repo-dir>]   (default $CLAUDE_PROJECT_DIR / cwd)
#
# exit 0 = no modified plan flagged (or nothing to gate); exit 1 = a modified
# plan is missing the section; exit 2 = usage / missing plan-shape-check.sh.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SELF_DIR/plan-shape-check.sh"
[ -f "$CHECK" ] || { echo "plan-shape-gate: plan-shape-check.sh not found at $CHECK" >&2; exit 2; }
# accuracy-trace-lint is a sibling that ships in the same plugin. The loop's
# `[ -f "$LINT" ]` soft-skip is deliberate graceful-degradation; the present-gate-
# but-absent-lint state can't actually occur because CHECK above hard-exits (2) on
# a broken/partial install, so this never silently drops enforcement in practice.
LINT="$SELF_DIR/accuracy-trace-lint.sh"

repo="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$repo" 2>/dev/null || { echo "plan-shape-gate: repo dir not found — $repo" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "plan-shape-gate: not a git repo; nothing to gate" >&2; exit 0; }

# Hardened base ref (never false-fail in degenerate git states):
#   git fetch (best-effort, so origin/main isn't stale → no over-scope) →
#   merge-base with origin/main → local main → upstream → HEAD~1 → clear no-op.
git fetch --quiet origin main 2>/dev/null || true
base=""
for ref in origin/main main "@{upstream}"; do
  git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
  base=$(git merge-base HEAD "$ref" 2>/dev/null) && [ -n "$base" ] && break
  base=""
done
[ -z "$base" ] && base=$(git rev-parse --verify --quiet "HEAD~1" 2>/dev/null || true)
if [ -z "$base" ]; then
  echo "plan-shape-gate: no base ref resolvable (fresh repo); nothing to gate" >&2
  exit 0
fi

# --diff-filter=AM → added/modified only (skip deleted/renamed → no "file not found").
fails=0
while IFS= read -r plan; do
  [ -z "$plan" ] && continue
  [ -f "$plan" ] || continue
  if ! bash "$CHECK" "$plan" >/dev/null 2>&1; then
    echo "plan-shape-gate: $plan is missing the '## AC count' section (plan-shape-check failed)" >&2
    fails=$((fails + 1))
  fi
  if [ -f "$LINT" ] && ! bash "$LINT" "$plan" >/dev/null 2>&1; then
    echo "plan-shape-gate: $plan failed accuracy-trace-lint (marked story w/ missing/invalid accuracy-trace map)" >&2
    fails=$((fails + 1))
  fi
done < <(git diff --name-only --diff-filter=AM "$base"..HEAD -- 'implementations/plans/*.md' 2>/dev/null || true)

[ "$fails" -gt 0 ] && exit 1
exit 0
