#!/usr/bin/env bash
# Story 085 - guards the migrations/entries/ per-version-file mechanism.
# Asserts: every entries/ filename is a valid semver OR a NEXT-<id> sprint
# placeholder; the step-9 ROW_V sort -V logic picks the true highest version
# (not lexical); on a clean checkout the three step-9 version sources agree
# once placeholders are resolved.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # = plugin/
ENTRIES_DIR="$REPO_ROOT/docs/superpowers/migrations/entries"
FAIL=0
fail() { echo "ERROR: $1" >&2; FAIL=1; }

# --- 1. every entries/ filename is semver X.Y.Z or a NEXT-<id> placeholder ---
# Both gates are anchored regexes (no loose glob): a resolved version file is
# X.Y.Z; a transient sprint placeholder is NEXT-<numeric story id>.
[ -d "$ENTRIES_DIR" ] || fail "entries/ directory not found"
for f in "$ENTRIES_DIR"/*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .md)"
  if printf '%s\n' "$base" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    :   # resolved version file
  elif printf '%s\n' "$base" | grep -qE '^NEXT-[0-9]+$'; then
    :   # transient sprint placeholder
  else
    fail "entries/ filename is neither a semver nor a NEXT-<id> placeholder: $base"
  fi
done

# --- 2. ROW_V sort -V picks the true highest version (not lexical) ----------
fixture="$(mktemp -d)"
for v in 3.9.0 3.10.0 3.21.0 3.2.0; do : > "$fixture/$v.md"; done
: > "$fixture/NEXT-099.md"   # placeholder must be ignored
row_v=$(ls "$fixture"/*.md 2>/dev/null | sed 's#.*/##; s#\.md$##' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
[ "$row_v" = "3.21.0" ] || fail "sort -V ROW_V resolved '$row_v', expected 3.21.0 (lexical would give 3.9.0)"
rm -rf "$fixture"

# --- 3. step-9 three sources agree on a clean checkout ----------------------
# PJ_V = plugin.json; MGR_V = _manager-startup.md literal; ROW_V = highest
# resolved entries/ filename. On a sprint branch the only entry may be a
# NEXT-<id> placeholder (ROW_V empty) -- that is the legitimate pre-merge
# state, so the agreement check is asserted only when ROW_V is non-empty.
PJ_V=$(jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
MGR_V=$(grep -oE 'plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`' "$REPO_ROOT/commands/_manager-startup.md" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
ROW_V=$(ls "$ENTRIES_DIR"/*.md 2>/dev/null | sed 's#.*/##; s#\.md$##' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
[ "$PJ_V" = "$MGR_V" ] || fail "plugin.json ($PJ_V) and _manager-startup.md literal ($MGR_V) disagree"
if [ -n "$ROW_V" ]; then
  [ "$ROW_V" = "$PJ_V" ] || fail "highest entries/ version ($ROW_V) disagrees with plugin.json ($PJ_V)"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "migration-entries-coherence: FAIL" >&2
  exit 1
fi
echo "migration-entries-coherence: PASS"
exit 0
