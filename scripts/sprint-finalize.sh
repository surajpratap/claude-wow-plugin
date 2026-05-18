#!/usr/bin/env bash
# sprint-finalize.sh — whole-sprint integration→main finalization helper.
#
# Args:
#   --target <X.Y.Z>   (required) — the final version this sprint stamps onto main.
#   --dry-run          (optional) — print the planned actions; mutate nothing
#                                   (no git ops, no working-tree writes, no commit).
#
# Behavior (in order):
#   1. Pre-rebase onto origin/<canonical>; abort cleanly on conflict.
#   2. Resolve <NEXT-from>/<NEXT-to> placeholders in entries/NEXT-*.md.
#   3. Consolidate the resolved per-story entries into entries/<target>.md.
#   4. Stamp plugin.json `.version` and the "M targets plugin version
#      **`X.Y.Z`**" literal in commands/_manager-startup.md.
#   5. Pre-flight: version-coherence.sh + migration-entries-coherence.sh.
#   6. Commit.
#
# Idempotent: a re-run on a genuinely-finalized branch (no NEXT-*.md remain,
# version already == target, working tree clean, origin/<canonical> is an
# ancestor of HEAD) exits 0 as a no-op. A "main-advanced" state re-rebases.
# A "step-(e)-aborted" state (resolves/stamps staged-but-uncommitted) is NOT
# treated as finalized.
#
# Exit codes:
#   0 — success (including no-op on already-finalized)
#   1 — fatal mid-finalization (rebase conflict, mutation failure, pre-flight)
#   2 — usage / precondition (bad --target, missing manifest, wrong branch)
#   3 — leftover <NEXT-…> placeholder after resolution

set -u

# Sourceable guard — tests source this file to exercise the helpers without
# the main flow firing.
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
  _SPRINT_FINALIZE_SOURCED=1
fi

# ---- helpers (deterministic; sourceable from tests) ----

# Portable component-wise semver compare. Echoes one of: lt | eq | gt.
# Exit 0 on a parseable compare; exit 2 on malformed input.
_semver_cmp() {
  local a="$1" b="$2"
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<EOF
$a
EOF
  IFS=. read -r b1 b2 b3 <<EOF
$b
EOF
  case "$a1$a2$a3$b1$b2$b3" in
    *[!0-9]*|"") echo "malformed semver: '$a' vs '$b'" >&2; return 2 ;;
  esac
  if [ "$a1" -lt "$b1" ]; then echo lt; return 0; fi
  if [ "$a1" -gt "$b1" ]; then echo gt; return 0; fi
  if [ "$a2" -lt "$b2" ]; then echo lt; return 0; fi
  if [ "$a2" -gt "$b2" ]; then echo gt; return 0; fi
  if [ "$a3" -lt "$b3" ]; then echo lt; return 0; fi
  if [ "$a3" -gt "$b3" ]; then echo gt; return 0; fi
  echo eq
}

# _resolve_next_file <file> <CUR> <TARGET>
# Substitutes <NEXT-from>/<NEXT-to> in $file in place. Honors $DRY_RUN.
_resolve_next_file() {
  local f="$1" cur="$2" target="$3"
  if [ -n "${DRY_RUN:-}" ]; then
    echo "would: resolve <NEXT-from>=$cur, <NEXT-to>=$target in $f"
    return 0
  fi
  sed -i.bak "s|<NEXT-from>|$cur|g; s|<NEXT-to>|$target|g" "$f" || {
    echo "FATAL: resolve failed for $f" >&2; return 1; }
  rm -f "$f.bak"
}

# _consolidate_entries <entry-dir> <CUR> <TARGET>
# Concatenates entries/NEXT-*.md (sorted) into entries/<target>.md, stripping
# each source's leading "# …" header line and prepending an "## <story-id>"
# subheading per entry under a single "# `<cur>` → `<target>`" header.
# Does NOT git rm the NEXT-*.md files — the caller does that (so tests can
# exercise consolidation independently of git).
_consolidate_entries() {
  local dir="$1" cur="$2" target="$3"
  local out="$dir/${target}.md"
  local files=()
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(ls -1 "$dir"/NEXT-*.md 2>/dev/null | sort)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "no NEXT-*.md entries to consolidate in $dir" >&2
    return 1
  fi
  if [ -n "${DRY_RUN:-}" ]; then
    echo "would: write $out — consolidating ${#files[@]} entries:"
    printf '  %s\n' "${files[@]}"
    return 0
  fi
  {
    printf '# \x60%s\x60 → \x60%s\x60\n\n' "$cur" "$target"
    for f in "${files[@]}"; do
      local sid
      sid=$(basename "$f" .md | sed 's|^NEXT-||')
      printf '## %s\n\n' "$sid"
      # Skip the leading "# …" header line; emit the rest of the body verbatim.
      sed -n '/^# /,$ { /^# /d; p; }' "$f"
      printf '\n'
    done
  } > "$out" || { echo "FATAL: consolidated entry write failed: $out" >&2; return 1; }
}

# _stamp_plugin_json <plugin-json> <target>
_stamp_plugin_json() {
  local pj="$1" target="$2"
  if [ -n "${DRY_RUN:-}" ]; then
    echo "would: jq --arg v $target '.version=\$v' $pj"
    return 0
  fi
  jq --arg v "$target" '.version = $v' "$pj" > "$pj.tmp" \
    && mv "$pj.tmp" "$pj" \
    || { echo "FATAL: plugin.json stamp failed" >&2; return 1; }
}

# _stamp_manager_startup <manager-startup-md> <target>
# Reuses sprint-merge-bump.sh's verified sed pattern verbatim (single-quoted
# regex body so bash double-quotes don't eat the backticks).
_stamp_manager_startup() {
  local ms="$1" target="$2"
  if [ -n "${DRY_RUN:-}" ]; then
    echo "would: sed 'M targets plugin version **\`X.Y.Z\`**' → $target in $ms"
    return 0
  fi
  sed -i.bak -E 's|M targets plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`\*\*|M targets plugin version **`'"$target"'`**|' "$ms" \
    || { echo "FATAL: _manager-startup.md stamp failed" >&2; return 1; }
  rm -f "$ms.bak"
}

# _check_leftover_placeholders <entry-dir>
# Greps the entries dir for any unresolved <NEXT-from|to>. Exits non-zero if any.
_check_leftover_placeholders() {
  local dir="$1"
  if grep -rlE '<NEXT-(from|to)>' "$dir" 2>/dev/null | grep -q .; then
    echo "FATAL: unresolved <NEXT-…> placeholder remains in $dir" >&2
    grep -rnE '<NEXT-(from|to)>' "$dir" >&2 || true
    return 3
  fi
}

# When sourced for testing, stop here.
[ -n "${_SPRINT_FINALIZE_SOURCED:-}" ] && return 0 2>/dev/null

# ---- main flow ----

TARGET=""
DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --target=*) TARGET="${1#--target=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's|^# \{0,1\}||'
      exit 0 ;;
    *) echo "usage: $0 --target <X.Y.Z> [--dry-run]" >&2; exit 2 ;;
  esac
done

if [ -z "$TARGET" ] || ! printf '%s' "$TARGET" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "usage: $0 --target <X.Y.Z> [--dry-run]" >&2
  exit 2
fi
export DRY_RUN

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CANONICAL_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^refs/remotes/origin/@@')
CANONICAL_BRANCH="${CANONICAL_BRANCH:-main}"

PLUGIN_JSON="$ROOT/plugin/.claude-plugin/plugin.json"
MGR_STARTUP="$ROOT/plugin/commands/_manager-startup.md"
ENTRY_DIR="$ROOT/plugin/docs/superpowers/migrations/entries"

# Precondition: working tree clean.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "refused: working tree not clean (commit or stash first)" >&2
  exit 2
fi

# Precondition: HEAD branch is the sprint integration branch (^sprint/).
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
case "$BRANCH" in
  sprint/*) : ;;
  *)
    echo "refused: HEAD must be a sprint/* integration branch (got '$BRANCH')" >&2
    exit 2 ;;
esac

# (a) Pre-rebase — fatal on fetch failure, abort cleanly on rebase conflict.
if [ -n "$DRY_RUN" ]; then
  echo "would: git fetch origin $CANONICAL_BRANCH"
  echo "would: git rebase origin/$CANONICAL_BRANCH"
else
  git fetch origin "$CANONICAL_BRANCH" --quiet || {
    echo "FATAL: git fetch origin $CANONICAL_BRANCH failed (offline?)" >&2
    exit 1; }
  if ! git rebase "origin/$CANONICAL_BRANCH" --quiet; then
    git rebase --abort 2>/dev/null || true
    echo "FATAL: integration branch conflicts with origin/$CANONICAL_BRANCH — resolve manually" >&2
    exit 1
  fi
fi

CUR=$(git show "origin/$CANONICAL_BRANCH:plugin/.claude-plugin/plugin.json" 2>/dev/null \
  | jq -r .version 2>/dev/null)
if [ -z "$CUR" ] || [ "$CUR" = "null" ]; then
  echo "FATAL: could not read current version from origin/$CANONICAL_BRANCH:plugin/.claude-plugin/plugin.json" >&2
  exit 1
fi

# Idempotency gate (post-fetch): ALL must hold for a no-op:
#   (i) no entries/NEXT-*.md remain
#   (ii) plugin.json .version == target
#   (iii) working tree clean
#   (iv) origin/$CANONICAL_BRANCH is an ancestor of HEAD
HAS_NEXT=0
ls "$ENTRY_DIR"/NEXT-*.md >/dev/null 2>&1 && HAS_NEXT=1
CUR_LOCAL_VER=$(jq -r .version "$PLUGIN_JSON" 2>/dev/null)
TREE_CLEAN=1
{ git diff --quiet && git diff --cached --quiet; } || TREE_CLEAN=0
ANCESTOR=0
git merge-base --is-ancestor "origin/$CANONICAL_BRANCH" HEAD 2>/dev/null && ANCESTOR=1
if [ "$HAS_NEXT" -eq 0 ] && [ "$CUR_LOCAL_VER" = "$TARGET" ] \
   && [ "$TREE_CLEAN" -eq 1 ] && [ "$ANCESTOR" -eq 1 ]; then
  echo "already finalized at $TARGET — no-op exit 0"
  exit 0
fi

# Precondition (only when NOT in idempotent no-op): --target strictly > current canonical.
CMP=$(_semver_cmp "$TARGET" "$CUR") || exit 2
if [ "$CMP" != "gt" ]; then
  echo "refused: --target=$TARGET not strictly greater than current canonical version $CUR" >&2
  exit 2
fi

if [ ! -d "$ENTRY_DIR" ]; then
  echo "FATAL: entries dir not found: $ENTRY_DIR" >&2
  exit 1
fi
NEXT_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && NEXT_FILES+=("$f")
done < <(ls -1 "$ENTRY_DIR"/NEXT-*.md 2>/dev/null | sort)
if [ "${#NEXT_FILES[@]}" -eq 0 ]; then
  echo "FATAL: no entries/NEXT-*.md to finalize (need at least one)" >&2
  exit 1
fi

# (b) Resolve <NEXT-…> placeholders.
for f in "${NEXT_FILES[@]}"; do
  _resolve_next_file "$f" "$CUR" "$TARGET" || exit 1
done

# (c) Consolidate.
_consolidate_entries "$ENTRY_DIR" "$CUR" "$TARGET" || exit 1
for f in "${NEXT_FILES[@]}"; do
  if [ -n "$DRY_RUN" ]; then
    echo "would: git rm $f"
  else
    # -f because (b) sed-resolved each NEXT-*.md in place — git rm refuses
    # a "locally modified" file without --force.
    git rm -qf "$f" || { echo "FATAL: git rm failed for $f" >&2; exit 1; }
  fi
done

# Leftover-placeholder guard (after b+c).
if [ -z "$DRY_RUN" ]; then
  _check_leftover_placeholders "$ENTRY_DIR" || exit 3
fi

# (d) Stamp plugin.json + _manager-startup.md.
_stamp_plugin_json "$PLUGIN_JSON" "$TARGET" || exit 1
_stamp_manager_startup "$MGR_STARTUP" "$TARGET" || exit 1

# (e) Pre-flight.
if [ -z "$DRY_RUN" ]; then
  if [ -x "$ROOT/plugin/tests/version-coherence.sh" ]; then
    bash "$ROOT/plugin/tests/version-coherence.sh" >/dev/null || {
      echo "FATAL: pre-flight version-coherence.sh failed — changes staged, NOT committed" >&2
      exit 1; }
  fi
  if [ -x "$ROOT/plugin/tests/migration-entries-coherence.sh" ]; then
    bash "$ROOT/plugin/tests/migration-entries-coherence.sh" >/dev/null || {
      echo "FATAL: pre-flight migration-entries-coherence.sh failed — changes staged, NOT committed" >&2
      exit 1; }
  fi
else
  echo "would: bash plugin/tests/version-coherence.sh && plugin/tests/migration-entries-coherence.sh"
fi

# Commit.
SPRINT_ID=$(echo "$BRANCH" | sed -n 's|^sprint/||p')
if [ -z "$SPRINT_ID" ]; then
  SPRINT_ID=$(jq -r '.id // empty' "$ROOT/implementations/sprints/"*/manifest.json 2>/dev/null | head -1)
fi
SPRINT_ID="${SPRINT_ID:-sprint}"

if [ -n "$DRY_RUN" ]; then
  echo "would: git add $PLUGIN_JSON $MGR_STARTUP $ENTRY_DIR/${TARGET}.md"
  echo "would: git commit -m 'sprint: finalize $SPRINT_ID → v$TARGET'"
else
  git add "$PLUGIN_JSON" "$MGR_STARTUP" "$ENTRY_DIR/${TARGET}.md" \
    || { echo "FATAL: git add failed" >&2; exit 1; }
  git commit -m "sprint: finalize $SPRINT_ID → v$TARGET" --quiet \
    || { echo "FATAL: git commit failed (commit hook? signing? — investigate, do not bypass)" >&2; exit 1; }
  echo "finalized $SPRINT_ID → v$TARGET (entry: $ENTRY_DIR/${TARGET}.md)"
fi

exit 0
