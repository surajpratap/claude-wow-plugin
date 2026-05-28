#!/usr/bin/env bash
# sprint-merge-bump.sh — stamp version + merge a sprint PR atomically.
#
# Args: <pr-number>
# Optional env: WOW_SPRINT_MANIFEST=<path> to override manifest discovery.
#
# Reads manifest.items[].version_bump_type ∈ "major" | "minor" | "patch"
# (default "minor" with bus warning if missing). Computes NEXT from main's
# current version. Runs in the per-item worktree at .worktrees/<NNN>-<slug>/
# (created at sprint kickoff). Stamps three targets:
# (1) plugin.json `.version`; (2) the "M targets plugin version **`X.Y.Z`**"
# literal in commands/_manager-startup.md; (3) the per-version migration entry
# file — substitutes <NEXT-from>/<NEXT-to> inside
# docs/superpowers/migrations/entries/NEXT-<story-id>.md and `git mv`s it to
# entries/<NEXT>.md. Per A7, sed patterns containing literal backticks use
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
#   1 — fatal mid-substitution failure (git mv of the entry file failed; or a
#       version bump with no migrations/entries/NEXT-<id>.md file)
#   2 — usage / missing prereq (no PR, no manifest, no version, no worktree)
#   3 — unresolved <NEXT placeholder remains (step 6), or a NEXT-<id>.md
#       placeholder entry survived substitution (step 6b)

set -u

# Manifest auto-discovery. Defined at top so tests can source
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
# Story 113: assign-then-default form. The previous pipeline-fallback form
# was dead: sed exits 0 on empty input, so the pipeline exited 0 even when
# `git symbolic-ref` had failed; the trailing fallback never fired, leaving
# CANONICAL_BRANCH="". The `${VAR:-main}` form below applies the default
# when VAR is unset OR empty.
CANONICAL_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
CANONICAL_BRANCH="${CANONICAL_BRANCH:-main}"
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
cd "$WT_DIR" || exit 2

# 5. Apply substitutions.
PLUGIN_JSON="plugin/.claude-plugin/plugin.json"
MGR_STARTUP="plugin/commands/_manager-startup.md"
ENTRY_DIR="plugin/docs/superpowers/migrations/entries"

# 5a. plugin.json `.version`.
jq --arg v "$NEXT" '.version = $v' "$PLUGIN_JSON" > "$PLUGIN_JSON.tmp" && mv "$PLUGIN_JSON.tmp" "$PLUGIN_JSON"

# 5b. "M targets plugin version **`X.Y.Z`**" literal in _manager-startup.md.
# Single-quoted regex body per spec A7 (bash double-quotes eat backticks).
sed -i.bak -E 's|M targets plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`\*\*|M targets plugin version **`'"$NEXT"'`**|' "$MGR_STARTUP"
rm -f "$MGR_STARTUP.bak"

# 5c removed: the migration-playbook `.version` write in
# _manager-startup.md is a version-agnostic `<target>` placeholder — there is no
# per-release version literal there for the wrapper to stamp.

# 5d. Per-version migration entry: substitute <NEXT-from>/<NEXT-to>, rename to
# entries/<version>.md.
ENTRY_PLACEHOLDER="$ENTRY_DIR/NEXT-${ITEM_ID}.md"
ENTRY_FINAL="$ENTRY_DIR/${NEXT}.md"
# A version-bumping item MUST ship its migrations/entries/NEXT-<id>.md file —
# without it step-9 ROW_V has no file for the new version (a 117-class false
# version-coherence alarm). The `if [ -f ]` below is for non-bumping items only.
if [ "$NEXT" != "$CUR" ] && [ ! -f "$ENTRY_PLACEHOLDER" ]; then
  echo "FATAL: version bump $CUR -> $NEXT but no $ENTRY_PLACEHOLDER exists" >&2
  exit 1
fi
if [ -f "$ENTRY_PLACEHOLDER" ]; then
  sed -i.bak "s|<NEXT-from>|$CUR|g; s|<NEXT-to>|$NEXT|g" "$ENTRY_PLACEHOLDER"
  rm -f "$ENTRY_PLACEHOLDER.bak"
  git mv "$ENTRY_PLACEHOLDER" "$ENTRY_FINAL" || {
    echo "FATAL: git mv of the migration entry failed ($ENTRY_PLACEHOLDER -> $ENTRY_FINAL)" >&2
    exit 1
  }
fi

# 6. Validate no <NEXT placeholder remains in the FILES (per A2).
# Conditionally include ENTRY_FINAL only if it exists; using an array keeps the
# expansion safe under shellcheck (SC2046) without breaking the inclusion test.
PLACEHOLDER_FILES=("$PLUGIN_JSON" "$MGR_STARTUP")
[ -f "$ENTRY_FINAL" ] && PLACEHOLDER_FILES+=("$ENTRY_FINAL")
if grep -lE '<NEXT-(from|to)>' "${PLACEHOLDER_FILES[@]}" 2>/dev/null | grep -q .; then
  echo "FATAL: unresolved <NEXT> placeholder remains after substitution. Aborting merge." >&2
  printf '{"ts":"%s","from":"sprint-merge-bump","to":"manager-*","type":"merge-aborted","payload":{"reason":"unresolved <NEXT> placeholder","pr":%s,"branch":"%s"}}\n' \
    "$NOW_TS" "$PR" "$BRANCH" >> "$ROOT/implementations/.message-bus.jsonl" 2>/dev/null || true
  exit 3
fi

# 6b. Leaked-placeholder guard: no entries/NEXT-<id>.md may survive 5d (a failed
# git mv or a wrong ITEM_ID would leave one, breaking step-9 ROW_V on main).
if ls "$ENTRY_DIR"/NEXT-*.md >/dev/null 2>&1; then
  echo "FATAL: a NEXT-<id>.md placeholder entry survived substitution. Aborting merge." >&2
  printf '{"ts":"%s","from":"sprint-merge-bump","to":"manager-*","type":"merge-aborted","payload":{"reason":"leaked NEXT placeholder entry","pr":%s,"branch":"%s"}}\n' \
    "$NOW_TS" "$PR" "$BRANCH" >> "$ROOT/implementations/.message-bus.jsonl" 2>/dev/null || true
  exit 3
fi

# 7. Commit (idempotent — skip if no diff after substitution). The 5d `git mv`
# already staged the renamed entry file; add the other two targets.
git add "$PLUGIN_JSON" "$MGR_STARTUP" 2>/dev/null || true
if ! git diff --cached --quiet; then
  # Branch shape accepts both feat/<NNN>-slug (legacy) and feat/<team>/<NNN>-slug
  #. The optional ([^/]+/)? consumes a team segment.
  STORY_ID=$(printf '%s' "$BRANCH" | sed -E 's|^feat/([^/]+/)?([0-9]+).*|\2|')
  git -c commit.gpgsign=false commit -m "chore: stamp version $NEXT on merge (story ${STORY_ID:-unknown})" --quiet
fi

# 8. Push.
git push --force-with-lease origin "HEAD:$BRANCH" --quiet 2>/dev/null || {
  echo "push failed for branch $BRANCH" >&2
  exit 2
}

# 9. Merge.
gh pr merge --squash --auto --delete-branch "$PR"
