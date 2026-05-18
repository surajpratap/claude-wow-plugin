#!/usr/bin/env bash
# sprint-merge-bump.sh wrapper test (Story 085 — per-version-entries rewrite).
#
# Synthetic-fixture bash test. Per-case mktemp -d isolation. Exercises the
# wrapper's step-5 substitution + validation logic via an inline bash mirror
# (so the test is independent of git/gh/network).
#
# Post-Story-085 contract — three stamp targets:
#   1. plugin.json `.version`
#   2. "M targets plugin version **`X.Y.Z`**" literal in commands/_manager-startup.md
#   3. migrations/entries/NEXT-<id>.md -- <NEXT-from>/<NEXT-to> substituted, file
#      renamed to entries/<NEXT>.md
# 5c (the old migration-playbook printf stamp) is gone -- the playbook .version
# write is a version-agnostic `<target>` placeholder; the test asserts it is
# left untouched.
#
# Cases:
# 1. minor-bump (default)        5. unresolved-<NEXT> aborts (rc 3)
# 2. patch-bump                  6. idempotent re-run is a no-op
# 3. major-bump                  7. gh PR lookup failure -> wrapper exit 2
# 4. missing-bump-type -> minor

set -u

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

# Fixture story id used in the entries/NEXT-<id>.md placeholder filename.
FIXTURE_ID="099"

# Inline mirror of the wrapper's step 5 (post-Story-085). The fixture is not a
# git repo, so 5d uses plain mv (the wrapper uses git mv for index staging).
# Returns 0 on clean substitution; 3 if a <NEXT> placeholder remains.
do_substitute() {
  local fix="$1" cur="$2" next="$3"
  local pj="$fix/.claude-plugin/plugin.json"
  local mgr="$fix/commands/_manager-startup.md"
  local entry_dir="$fix/docs/superpowers/migrations/entries"
  local placeholder="$entry_dir/NEXT-$FIXTURE_ID.md"
  local final="$entry_dir/$next.md"

  # 5a. plugin.json version key.
  jq --arg v "$next" '.version = $v' "$pj" > "$pj.tmp" && mv "$pj.tmp" "$pj"

  # 5b. "M targets plugin version **`X.Y.Z`**" literal in _manager-startup.md.
  sed -i.bak -E 's|M targets plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`\*\*|M targets plugin version **`'"$next"'`**|' "$mgr"
  rm -f "$mgr.bak"

  # 5c: gone -- nothing to stamp in the version-agnostic <target> playbook line.

  # 5d. Per-version migration entry: substitute placeholders, rename.
  if [ -f "$placeholder" ]; then
    sed -i.bak "s|<NEXT-from>|$cur|g; s|<NEXT-to>|$next|g" "$placeholder"
    rm -f "$placeholder.bak"
    mv "$placeholder" "$final"
  fi

  # 6. Validate no <NEXT placeholder remains in the stamped files. Array form
  # keeps the conditional include shellcheck-safe (SC2046 quoting).
  local placeholder_files=("$pj" "$mgr")
  [ -f "$final" ] && placeholder_files+=("$final")
  if grep -lE '<NEXT-(from|to)>' "${placeholder_files[@]}" 2>/dev/null | grep -q .; then
    return 3
  fi
  # 6b. No NEXT-<id>.md placeholder survives.
  if ls "$entry_dir"/NEXT-*.md >/dev/null 2>&1; then
    return 3
  fi
  return 0
}

# Build a fixture: plugin.json @ $cur; _manager-startup.md with the version
# literal + a version-agnostic <target> playbook printf line; an
# entries/NEXT-<id>.md migration-entry placeholder.
mk_fixture() {
  local cur="$1"
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/.claude-plugin" "$dir/commands" "$dir/docs/superpowers/migrations/entries"
  printf '{"name":"claude-wow","version":"%s"}\n' "$cur" > "$dir/.claude-plugin/plugin.json"
  cat > "$dir/commands/_manager-startup.md" <<EOF
## Plugin version

M targets plugin version **\`$cur\`**. This literal is used in Phase 1.

## Migration playbook

   After transforms, write the target version to \`.version\`:
   \`\`\`bash
   printf '%s\n' "<target>" > "\${ROOT}/implementations/.version"
   \`\`\`
EOF
  cat > "$dir/docs/superpowers/migrations/entries/NEXT-$FIXTURE_ID.md" <<'EOF'
# `<NEXT-from>` -> `<NEXT-to>`

Test migration entry seeded by the branch.
EOF
  echo "$dir"
}

assert_targets() {
  local case_id="$1" fix="$2" cur="$3" next="$4"
  local pj="$fix/.claude-plugin/plugin.json"
  local mgr="$fix/commands/_manager-startup.md"
  local entry_dir="$fix/docs/superpowers/migrations/entries"

  # 1. plugin.json version.
  assert_eq "$case_id-plugin-json" "$next" "$(jq -r '.version' "$pj")"

  # 2. "M targets plugin version **`X.Y.Z`**" literal in _manager-startup.md.
  local hdr; hdr=$(grep -oE 'M targets plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`' "$mgr" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  assert_eq "$case_id-mgr-literal" "$next" "$hdr"

  # 3. 5c gone -- the version-agnostic <target> playbook line is untouched.
  local target_present="no"
  grep -qF 'printf '"'"'%s\n'"'"' "<target>"' "$mgr" && target_present="yes"
  assert_eq "$case_id-playbook-untouched" "yes" "$target_present"

  # 4. Entry file renamed NEXT-<id>.md -> <next>.md, placeholders substituted,
  #    no <NEXT> left.
  local entry_ok="no"
  if [ -f "$entry_dir/$next.md" ] \
     && [ ! -f "$entry_dir/NEXT-$FIXTURE_ID.md" ] \
     && grep -qF "$cur" "$entry_dir/$next.md" \
     && grep -qF "$next" "$entry_dir/$next.md" \
     && ! grep -qE '<NEXT-(from|to)>' "$entry_dir/$next.md"; then
    entry_ok="yes"
  fi
  assert_eq "$case_id-entry-renamed-substituted" "yes" "$entry_ok"
}

# --- Case 1: minor bump --------------------------------------------------
DIR=$(mk_fixture "2.24.1")
NEXT=$(bump_part "2.24.1" "minor")
do_substitute "$DIR" "2.24.1" "$NEXT"; RC=$?
assert_eq "case-1-minor-rc" "0" "$RC"
assert_eq "case-1-minor-NEXT" "2.25.0" "$NEXT"
assert_targets "case-1-minor" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# --- Case 2: patch bump --------------------------------------------------
DIR=$(mk_fixture "2.24.1")
NEXT=$(bump_part "2.24.1" "patch")
do_substitute "$DIR" "2.24.1" "$NEXT"
assert_eq "case-2-patch-NEXT" "2.24.2" "$NEXT"
assert_targets "case-2-patch" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# --- Case 3: major bump --------------------------------------------------
DIR=$(mk_fixture "2.24.1")
NEXT=$(bump_part "2.24.1" "major")
do_substitute "$DIR" "2.24.1" "$NEXT"
assert_eq "case-3-major-NEXT" "3.0.0" "$NEXT"
assert_targets "case-3-major" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# --- Case 4: missing bump-type defaults to minor -------------------------
DIR=$(mk_fixture "2.24.1")
DEFAULT_TYPE="${VERSION_BUMP_TYPE:-minor}"
NEXT=$(bump_part "2.24.1" "$DEFAULT_TYPE")
assert_eq "case-4-default-type" "minor" "$DEFAULT_TYPE"
assert_eq "case-4-default-NEXT" "2.25.0" "$NEXT"
do_substitute "$DIR" "2.24.1" "$NEXT"
assert_targets "case-4-default" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# --- Case 5: unresolved <NEXT> aborts ------------------------------------
# Stray placeholder in plugin.json description — jq's version-key substitution
# won't touch it, so step-6 validation must catch it (rc 3).
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude-plugin" "$DIR/commands" "$DIR/docs/superpowers/migrations/entries"
printf '{"name":"claude-wow","version":"2.24.1","description":"contains <NEXT-from> stray"}\n' > "$DIR/.claude-plugin/plugin.json"
printf '## Plugin version\n\nM targets plugin version **`2.24.1`**.\n' > "$DIR/commands/_manager-startup.md"
NEXT=$(bump_part "2.24.1" "minor")
do_substitute "$DIR" "2.24.1" "$NEXT" 2>/dev/null; RC=$?
assert_eq "case-5-unresolved-NEXT-rc" "3" "$RC"
rm -rf "$DIR"

# --- Case 6: idempotent re-run -------------------------------------------
DIR=$(mk_fixture "2.24.1")
NEXT=$(bump_part "2.24.1" "minor")
do_substitute "$DIR" "2.24.1" "$NEXT"
do_substitute "$DIR" "2.24.1" "$NEXT"; RC=$?
assert_eq "case-6-idempotent-rc" "0" "$RC"
assert_eq "case-6-still-bumped" "2.25.0" "$(jq -r '.version' "$DIR/.claude-plugin/plugin.json")"
assert_targets "case-6-idempotent" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# --- Case 7: gh PR lookup failure -> wrapper exits 2 ---------------------
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
echo "mock gh: error" >&2
exit 1
SHIM
chmod +x "$SHIM_DIR/gh"
WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/scripts/sprint-merge-bump.sh"
PATH="$SHIM_DIR:$PATH" bash "$WRAPPER" 999 2>/dev/null; RC=$?
assert_eq "case-7-gh-failure-rc" "2" "$RC"
rm -rf "$SHIM_DIR"

echo
echo "sprint-merge-bump: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
