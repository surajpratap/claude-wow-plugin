#!/usr/bin/env bash
# sprint-merge-bump.sh — stamp version + merge a sprint PR atomically.
#
# Args: <pr-number>
# Optional env: WOW_SPRINT_MANIFEST=<path> to override manifest discovery.
#
# Reads manifest.items[].version_bump_type ∈ "major" | "minor" | "patch"
# (default "minor" with bus warning if missing). Computes NEXT from main's
# current version. Runs in the per-item worktree at .worktrees/<NNN>-<slug>/
# (created at sprint kickoff). Substitutes THREE manager.md targets per spec
# amendment A6: (1) "M targets plugin version **`X.Y.Z`**" header literal,
# (2) migration playbook printf '%s\n' "X.Y.Z" > .../.version line,
# (3) migration row <NEXT-from> / <NEXT-to> placeholders. Plus plugin.json
# `.version`. Per A7, sed patterns containing literal backticks use
# SINGLE-quoted regex bodies (bash double-quotes interpret backticks as
# command substitution, silently eats the regex content).
#
# Validates no <NEXT-from>/<NEXT-to> remain by grepping the FILES (not git
# diff — diff still contains removed lines, false-positive). Per A2.
#
# Idempotent: re-running on an already-bumped branch is a no-op (no-diff
# commit skipped; push is a no-op; gh pr merge --squash --auto is
# idempotent for the same SHA).
#
# Exit codes:
#   0 — success
#   2 — usage / missing prereq (no PR, no manifest, no version, no worktree)
#   3 — unresolved <NEXT placeholder remains after substitution

set -u

# Manifest auto-discovery (Story 056). Defined at top so tests can source
# this script without executing the main flow (sourceable guard below).
# Honor explicit override; otherwise prefer the in-progress sprint manifest;
# fall back to the lexicographically-last manifest when no sprint is active
# (graceful degradation for one-off backlog promotions). Multi-active is a
# state bug — fail loud (exit 2) per Story 056 AC #2.
_discover_manifest() {
  if [ -n "${WOW_SPRINT_MANIFEST:-}" ]; then
    echo "$WOW_SPRINT_MANIFEST"
    return 0
  fi

  local sprints_dir="$ROOT/implementations/sprints"
  [ -d "$sprints_dir" ] || return 1

  local in_progress=()
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    local mstatus
    mstatus=$(jq -r '.status // empty' "$path" 2>/dev/null)
    [ "$mstatus" = "in-progress" ] && in_progress+=("$path")
  done < <(ls -1d "$sprints_dir"/*/manifest.json 2>/dev/null)

  if [ "${#in_progress[@]}" -eq 1 ]; then
    echo "${in_progress[0]}"
    return 0
  fi
  if [ "${#in_progress[@]}" -gt 1 ]; then
    echo "MULTIPLE in-progress sprint manifests detected (M coordinates one sprint at a time):" >&2
    printf '  %s\n' "${in_progress[@]}" >&2
    return 2
  fi

  ls -1d "$sprints_dir"/*/manifest.json 2>/dev/null | tail -1
}

# Sourceable guard: when this file is `source`d (e.g., from a test that wants
# to call `_discover_manifest` in isolation), return now and skip the main
# flow. When executed directly, BASH_SOURCE[0] == $0 and we proceed.
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
  return 0 2>/dev/null || true
fi

PR="${1:-}"
if [ -z "$PR" ]; then
  echo "usage: $0 <pr-number>" >&2
  exit 2
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CANONICAL_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)
NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 1. Look up PR's branch + sprint manifest.
BRANCH=$(gh pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null)
if [ -z "$BRANCH" ]; then
  echo "could not look up PR $PR via gh" >&2
  exit 2
fi

MANIFEST=$(_discover_manifest)
disco_rc=$?
if [ "$disco_rc" -eq 2 ]; then
  exit 2
fi
if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
  echo "no manifest found (looked at \$WOW_SPRINT_MANIFEST and $ROOT/implementations/sprints/*/manifest.json)" >&2
  exit 2
fi

ITEM=$(jq -c --arg branch "$BRANCH" '.items[] | select(.branch == $branch)' "$MANIFEST")
if [ -z "$ITEM" ]; then
  echo "no manifest item for branch $BRANCH" >&2
  exit 2
fi

BUMP_TYPE=$(echo "$ITEM" | jq -r '.version_bump_type // empty')
if [ -z "$BUMP_TYPE" ] || [ "$BUMP_TYPE" = "null" ]; then
  BUMP_TYPE="minor"
  printf '{"ts":"%s","from":"sprint-merge-bump","to":"manager-*","type":"migration-row-warning","payload":{"reason":"missing version_bump_type — defaulted to minor","pr":%s,"branch":"%s"}}\n' \
    "$NOW_TS" "$PR" "$BRANCH" >> "$ROOT/implementations/.message-bus.jsonl" 2>/dev/null || true
fi

# 2. Read main's current version.
git fetch origin "$CANONICAL_BRANCH" --quiet 2>/dev/null || true
CUR=$(git show "origin/$CANONICAL_BRANCH:plugin/.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version' 2>/dev/null)
if [ -z "$CUR" ]; then
  echo "could not read current version from origin/$CANONICAL_BRANCH" >&2
  exit 2
fi

# 3. Compute NEXT.
bump_part() {
  local v="$1" type="$2"
  local M m p
  IFS=. read -r M m p <<< "$v"
  case "$type" in
    major) echo "$((M+1)).0.0" ;;
    minor) echo "$M.$((m+1)).0" ;;
    patch) echo "$M.$m.$((p+1))" ;;
    *) echo "$v" ;;
  esac
}
NEXT=$(bump_part "$CUR" "$BUMP_TYPE")
if [ -z "$NEXT" ] || [ "$NEXT" = "$CUR" ]; then
  echo "could not compute NEXT version from CUR=$CUR BUMP_TYPE=$BUMP_TYPE" >&2
  exit 2
fi

# 4. cd into existing per-item worktree (per spec A3).
ITEM_ID=$(echo "$ITEM" | jq -r '.id')
SLUG=$(echo "$ITEM" | jq -r '.story | split("/") | last | sub("\\.md$"; "") | sub("^[0-9]+-"; "")')
WT_DIR="$ROOT/.worktrees/$ITEM_ID-$SLUG"
if [ ! -d "$WT_DIR" ]; then
  echo "FATAL: per-item worktree $WT_DIR does not exist" >&2
  exit 2
fi
cd "$WT_DIR"

# 5. Apply substitutions.
PLUGIN_JSON="plugin/.claude-plugin/plugin.json"
MGR_MD="plugin/commands/manager.md"

# 5a. plugin.json `.version`.
jq --arg v "$NEXT" '.version = $v' "$PLUGIN_JSON" > "$PLUGIN_JSON.tmp" && mv "$PLUGIN_JSON.tmp" "$PLUGIN_JSON"

# 5b–d. THREE manager.md substitutions per spec A6, all SINGLE-quoted per A7.
# Pattern: substitute the regex literal in single quotes, splice $CUR/$NEXT
# in via interpolation-only single-quote-break-and-double-quote-fragment.

# 5b. "M targets plugin version **`X.Y.Z`**" header literal.
sed -i.bak -E 's|M targets plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`\*\*|M targets plugin version **`'"$NEXT"'`**|' "$MGR_MD"

# 5c. Migration playbook printf line.
sed -i.bak -E 's|printf '"'"'%s\\n'"'"' "[0-9]+\.[0-9]+\.[0-9]+" > "\$\{ROOT\}/implementations/\.version"|printf '"'"'%s\\n'"'"' "'"$NEXT"'" > "${ROOT}/implementations/.version"|' "$MGR_MD"

# 5d. Migration table NEW row's <NEXT-from>/<NEXT-to> placeholders.
sed -i.bak "s|<NEXT-from>|$CUR|g" "$MGR_MD"
sed -i.bak "s|<NEXT-to>|$NEXT|g" "$MGR_MD"
rm -f "$MGR_MD.bak"

# 6. Validate no <NEXT placeholder remains in the FILES (per A2).
if grep -lE '<NEXT-(from|to)>' "$PLUGIN_JSON" "$MGR_MD" 2>/dev/null | grep -q .; then
  echo "FATAL: unresolved <NEXT> placeholder remains in plugin.json or manager.md after substitution. Aborting merge." >&2
  printf '{"ts":"%s","from":"sprint-merge-bump","to":"manager-*","type":"merge-aborted","payload":{"reason":"unresolved <NEXT> placeholder","pr":%s,"branch":"%s"}}\n' \
    "$NOW_TS" "$PR" "$BRANCH" >> "$ROOT/implementations/.message-bus.jsonl" 2>/dev/null || true
  exit 3
fi

# 7. Commit (idempotent — skip if no diff after substitution).
git add "$PLUGIN_JSON" "$MGR_MD" 2>/dev/null || true
if ! git diff --cached --quiet; then
  STORY_ID=$(echo "$BRANCH" | grep -oE '^feat/[0-9]+' | sed 's|^feat/||')
  git -c commit.gpgsign=false commit -m "chore: stamp version $NEXT on merge (story ${STORY_ID:-unknown})" --quiet
fi

# 8. Push.
git push --force-with-lease origin "HEAD:$BRANCH" --quiet 2>/dev/null || {
  echo "push failed for branch $BRANCH" >&2
  exit 2
}

# 9. Merge.
gh pr merge --squash --auto --delete-branch "$PR"
