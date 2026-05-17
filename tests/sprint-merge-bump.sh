#!/usr/bin/env bash
# Story 027 — sprint-merge-bump.sh wrapper test.
#
# Synthetic-fixture bash test. Per-case mktemp -d isolation.
# Exercises the wrapper's substitution + validation logic on synthetic
# plugin.json + manager.md fixtures via inline bash mirror of the wrapper's
# substitution code (so the test is independent of git/gh/network).
#
# Per spec amendment A7: assertions cover all four post-state targets to
# catch the bash-backtick-in-double-quotes silent-eat class of bug:
#   1. plugin.json `.version`
#   2. "M targets plugin version **`X.Y.Z`**" header literal
#   3. Migration playbook printf '%s\n' "X.Y.Z" line
#   4. Migration row <NEXT-from>/<NEXT-to> placeholders substituted
#
# Cases:
# 1. minor-bump (default): all 4 targets correctly bumped, no <NEXT remains
# 2. patch-bump
# 3. major-bump
# 4. missing-bump-type-defaults-to-minor
# 5. unresolved-NEXT aborts (synthetic stray placeholder remains → exit 3)
# 6. idempotent-already-stamped: re-run on already-bumped fixture is a no-op
# 7. gh-pr-checkout-failure: real wrapper invocation with mock gh → exit 2

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

# Inline pure-bash substitution helpers — mirror what the wrapper does.
# This is the spec for what the script's substitution step computes.
# CRITICAL (spec amendment A7): all sed patterns containing literal
# backticks use SINGLE-quoted regex bodies. Test failure here would
# also surface in the wrapper itself.

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

# Apply ALL FOUR substitutions to a fixture (per spec A6).
# Returns:
#   0 if substitution succeeded and no <NEXT> remains
#   3 if <NEXT> placeholder remains after substitution
do_substitute() {
  local fix="$1" cur="$2" next="$3"
  local pj="$fix/.claude-plugin/plugin.json"
  local mgr="$fix/commands/manager.md"

  # 1. plugin.json version key.
  jq --arg v "$next" '.version = $v' "$pj" > "$pj.tmp" && mv "$pj.tmp" "$pj"

  # 2. "M targets plugin version **`X.Y.Z`**" header literal.
  sed -i.bak -E 's|M targets plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`\*\*|M targets plugin version **`'"$next"'`**|' "$mgr"

  # 3. Migration playbook printf line.
  sed -i.bak -E 's|printf '"'"'%s\\n'"'"' "[0-9]+\.[0-9]+\.[0-9]+" > "\$\{ROOT\}/implementations/\.version"|printf '"'"'%s\\n'"'"' "'"$next"'" > "${ROOT}/implementations/.version"|' "$mgr"

  # 4. Migration table NEW row's <NEXT-from>/<NEXT-to> placeholders.
  sed -i.bak "s|<NEXT-from>|$cur|g" "$mgr"
  sed -i.bak "s|<NEXT-to>|$next|g" "$mgr"
  rm -f "$mgr.bak"

  if grep -lE '<NEXT-(from|to)>' "$pj" "$mgr" 2>/dev/null | grep -q .; then
    return 3
  fi
  return 0
}

# Build a fixture: plugin.json at $cur, manager.md with all THREE
# substitution targets (header literal + printf .version + migration row).
# Optional: extra raw text in manager.md (used by the unresolved-<NEXT> case).
mk_fixture() {
  local cur="$1" extra="${2:-}"
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/.claude-plugin" "$dir/commands"
  printf '{"name":"claude-wow","version":"%s"}\n' "$cur" > "$dir/.claude-plugin/plugin.json"
  cat > "$dir/commands/manager.md" <<EOF
## Plugin version

M targets plugin version **\`$cur\`**. This literal is used in Phase 1.

## Migration playbook

| From → To | Steps |
|-----------|-------|
| \`<NEXT-from>\` → \`<NEXT-to>\` | test row added by branch |

   After transforms, write the new version to \`.version\` (overwrite):
   \`\`\`bash
   printf '%s\n' "$cur" > "\${ROOT}/implementations/.version"
   \`\`\`

${extra}
EOF
  echo "$dir"
}

# -----------------------------------------------------------------------------
# Helper to assert all 4 substitution targets in a fixture.
# -----------------------------------------------------------------------------

assert_all_four_targets() {
  local case_id="$1" fix="$2" cur="$3" next="$4"
  local pj="$fix/.claude-plugin/plugin.json"
  local mgr="$fix/commands/manager.md"

  # 1. plugin.json version.
  local pj_v; pj_v=$(jq -r '.version' "$pj")
  assert_eq "$case_id-plugin-json" "$next" "$pj_v"

  # 2. "M targets plugin version **`X.Y.Z`**" header literal.
  local mgr_header; mgr_header=$(grep -oE 'M targets plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`' "$mgr" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  assert_eq "$case_id-mgr-header" "$next" "$mgr_header"

  # 3. Migration playbook printf line.
  local mgr_printf; mgr_printf=$(grep -oE 'printf '"'"'%s\\n'"'"' "[0-9]+\.[0-9]+\.[0-9]+"' "$mgr" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  assert_eq "$case_id-mgr-printf" "$next" "$mgr_printf"

  # 4. Migration row <NEXT-*> placeholders gone, substituted to $cur → $next.
  local row_present
  if grep -E "\| \`$cur\` → \`$next\`" "$mgr" >/dev/null 2>&1; then
    row_present="yes"
  else
    row_present="no"
  fi
  assert_eq "$case_id-mgr-row" "yes" "$row_present"

  # 5. No <NEXT placeholder remains anywhere.
  local placeholder_count; placeholder_count=$(grep -cE '<NEXT-(from|to)>' "$mgr")
  assert_eq "$case_id-no-placeholder" "0" "$placeholder_count"
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: minor bump — all four targets.
DIR=$(mk_fixture "2.24.1")
NEXT=$(bump_part "2.24.1" "minor")
do_substitute "$DIR" "2.24.1" "$NEXT"
RC=$?
assert_eq "case-1-minor-rc" "0" "$RC"
assert_eq "case-1-minor-NEXT-computed" "2.25.0" "$NEXT"
assert_all_four_targets "case-1-minor" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# Case 2: patch bump — all four targets.
DIR=$(mk_fixture "2.24.1")
NEXT=$(bump_part "2.24.1" "patch")
do_substitute "$DIR" "2.24.1" "$NEXT"
assert_eq "case-2-patch-NEXT-computed" "2.24.2" "$NEXT"
assert_all_four_targets "case-2-patch" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# Case 3: major bump — all four targets.
DIR=$(mk_fixture "2.24.1")
NEXT=$(bump_part "2.24.1" "major")
do_substitute "$DIR" "2.24.1" "$NEXT"
assert_eq "case-3-major-NEXT-computed" "3.0.0" "$NEXT"
assert_all_four_targets "case-3-major" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# Case 4: missing bump-type defaults to minor.
DIR=$(mk_fixture "2.24.1")
DEFAULT_TYPE="${VERSION_BUMP_TYPE:-minor}"
NEXT=$(bump_part "2.24.1" "$DEFAULT_TYPE")
assert_eq "case-4-default-bump-type" "minor" "$DEFAULT_TYPE"
assert_eq "case-4-default-NEXT" "2.25.0" "$NEXT"
do_substitute "$DIR" "2.24.1" "$NEXT"
assert_all_four_targets "case-4-default" "$DIR" "2.24.1" "$NEXT"
rm -rf "$DIR"

# Case 5: unresolved <NEXT> aborts — inject stray placeholder in plugin.json
# description field (jq's version-key substitution won't touch it).
DIR=$(mktemp -d)
mkdir -p "$DIR/.claude-plugin" "$DIR/commands"
printf '{"name":"claude-wow","version":"2.24.1","description":"contains <NEXT-from> stray"}\n' > "$DIR/.claude-plugin/plugin.json"
cat > "$DIR/commands/manager.md" <<'EOF'
## Plugin version

M targets plugin version **`2.24.1`**.
EOF
NEXT=$(bump_part "2.24.1" "minor")
do_substitute "$DIR" "2.24.1" "$NEXT" 2>/dev/null
RC=$?
assert_eq "case-5-unresolved-NEXT-aborts-rc" "3" "$RC"
rm -rf "$DIR"

# Case 6: idempotent on already-bumped fixture (re-run is no-op).
DIR=$(mk_fixture "2.24.1")
NEXT=$(bump_part "2.24.1" "minor")
do_substitute "$DIR" "2.24.1" "$NEXT"
# Second invocation against already-stamped state.
do_substitute "$DIR" "2.24.1" "$NEXT"
RC=$?
assert_eq "case-6-idempotent-rc" "0" "$RC"
NEW_PV=$(jq -r '.version' "$DIR/.claude-plugin/plugin.json")
assert_eq "case-6-still-bumped" "2.25.0" "$NEW_PV"
# Header literal still bumped on the second pass.
NEW_HDR=$(grep -oE 'M targets plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`' "$DIR/commands/manager.md" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
assert_eq "case-6-header-still-bumped" "2.25.0" "$NEW_HDR"
rm -rf "$DIR"

# Case 7: gh PR lookup failure — wrapper exits 2.
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
echo "mock gh: error" >&2
exit 1
SHIM
chmod +x "$SHIM_DIR/gh"
WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/scripts/sprint-merge-bump.sh"
PATH="$SHIM_DIR:$PATH" bash "$WRAPPER" 999 2>/dev/null
RC=$?
assert_eq "case-7-gh-failure-rc" "2" "$RC"
rm -rf "$SHIM_DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "sprint-merge-bump: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
