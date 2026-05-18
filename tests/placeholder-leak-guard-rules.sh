#!/usr/bin/env bash
# Story 115 — mechanical guard against `<NEXT>` placeholder leaks shipping
# to consumers via a UI merge bypass. The CI workflow
# `.github/workflows/placeholder-leak-guard.yml` invokes this script in
# the merge-candidate tree of any PR targeting `main`. Scope is
# `plugin/` ONLY (the consumer-facing tree); root-level source-repo
# artifacts (`implementations/plans/`, `AGENTS.md`, source specs)
# legitimately quote the placeholder convention in their bodies and are
# out of scope.
#
# Failure modes (the CI workflow surfaces these):
#   1. Any `plugin/docs/superpowers/migrations/entries/NEXT-*.md` file
#      present means `sprint-merge-bump.sh` / `sprint-finalize.sh` didn't
#      run before merge.
#   2. Any literal `<NEXT-from>` / `<NEXT-to>` token in `plugin/` OUTSIDE
#      the allow-list (convention-explanation sites + the wrappers +
#      the tests that exercise them).
#
# This file is run two ways:
#   (A) From the GitHub CI workflow — the merge candidate tree is clean of
#       placeholders (the wrappers ran before / placeholders are inside
#       the allow-list), so the real-tree scan reports no leaks.
#   (B) From `plugin/tests/run-all.sh` on any branch — including sprint
#       branches where NEXT-*.md files legitimately exist mid-sprint.
#       In that case the real-tree scan would (correctly) report leaks,
#       BUT that's not what we want to test locally. The local test
#       exercises only the RULE LOGIC against tmp fake-root fixtures:
#       (a) a leak fixture triggers the failure mode; (b) a clean
#       fixture passes. The CI workflow does the production scan.
#
# Exit 0 on clean rule logic; exit 1 on a smoke-test regression.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The scan logic, parameterized on a base directory. Returns 0 if no leaks,
# 1 if any leak is found. Stderr lists the leaking files. Same logic the
# CI workflow runs against `$PLUGIN_DIR` of the merge candidate.
scan_for_leaks() {
  local base="$1"
  local rc=0

  # Step 1: NEXT-*.md entry files.
  local entries
  entries=$(find "$base/docs/superpowers/migrations/entries" -maxdepth 1 -type f -name 'NEXT-*.md' 2>/dev/null)
  if [ -n "$entries" ]; then
    echo "[leak-guard] NEXT-<id>.md entry file(s) found:" >&2
    echo "$entries" | sed 's|^|  |' >&2
    rc=1
  fi

  # Step 2: <NEXT-from>/<NEXT-to> tokens outside the allow-list.
  local allow_patterns=(
    "commands/_agent-protocol.md"
    "commands/senior-developer.md"
    "commands/pair-programmer.md"
    "commands/manager.md"
    "commands/_retro-doctrine.md"
    "scripts/sprint-merge-bump.sh"
    "scripts/sprint-finalize.sh"
    "tests/*.sh"
  )
  local hits
  hits=$(grep -rln -E '<NEXT-(from|to)>' "$base" 2>/dev/null || true)
  local leaked=""
  while IFS= read -r match; do
    [ -z "$match" ] && continue
    local rel="${match#$base/}"
    local allowed=0
    for pat in "${allow_patterns[@]}"; do
      # shellcheck disable=SC2053
      if [[ "$rel" == $pat ]]; then
        allowed=1
        break
      fi
    done
    [ "$allowed" -eq 0 ] && leaked="${leaked}${rel}"$'\n'
  done <<< "$hits"
  if [ -n "$leaked" ]; then
    echo "[leak-guard] <NEXT-from>/<NEXT-to> token(s) found outside the allow-list:" >&2
    echo -n "$leaked" | sed 's|^|  |' >&2
    rc=1
  fi
  return $rc
}

# ---- Smoke (a): a clean fake-root passes (rc=0) ----
SMOKE_A=$(mktemp -d)
mkdir -p "$SMOKE_A/docs/superpowers/migrations/entries" "$SMOKE_A/commands" "$SMOKE_A/scripts" "$SMOKE_A/tests"
echo "# Real version entry — no placeholders." > "$SMOKE_A/docs/superpowers/migrations/entries/3.25.0.md"
scan_for_leaks "$SMOKE_A" 2>/dev/null
assert_eq "smoke-a-clean-root-rc0" "0" "$?"
rm -rf "$SMOKE_A"

# ---- Smoke (b): NEXT-*.md fixture triggers step 1 failure ----
SMOKE_B=$(mktemp -d)
mkdir -p "$SMOKE_B/docs/superpowers/migrations/entries"
echo "# stray placeholder entry" > "$SMOKE_B/docs/superpowers/migrations/entries/NEXT-999.md"
scan_for_leaks "$SMOKE_B" 2>/dev/null
assert_eq "smoke-b-NEXT-md-triggers-fail" "1" "$?"
rm -rf "$SMOKE_B"

# ---- Smoke (c): <NEXT-from> token in a non-allow-listed path triggers step 2 ----
SMOKE_C=$(mktemp -d)
mkdir -p "$SMOKE_C/docs/superpowers/migrations/entries" "$SMOKE_C/commands"
echo "Stray <NEXT-from> in fake-other.md" > "$SMOKE_C/commands/fake-other.md"
scan_for_leaks "$SMOKE_C" 2>/dev/null
assert_eq "smoke-c-token-outside-allowlist-fail" "1" "$?"
rm -rf "$SMOKE_C"

# ---- Smoke (d): <NEXT-from> in an allow-listed path passes ----
SMOKE_D=$(mktemp -d)
mkdir -p "$SMOKE_D/docs/superpowers/migrations/entries" "$SMOKE_D/commands"
echo "Allow-listed: <NEXT-from> + <NEXT-to> placeholders quoted in convention." \
  > "$SMOKE_D/commands/_agent-protocol.md"
scan_for_leaks "$SMOKE_D" 2>/dev/null
assert_eq "smoke-d-allow-listed-path-passes" "0" "$?"
rm -rf "$SMOKE_D"

# ---- Smoke (e): tests/*.sh glob allow-list matches ----
SMOKE_E=$(mktemp -d)
mkdir -p "$SMOKE_E/docs/superpowers/migrations/entries" "$SMOKE_E/tests"
echo "# test file referencing <NEXT-from> placeholder convention" \
  > "$SMOKE_E/tests/some-test.sh"
scan_for_leaks "$SMOKE_E" 2>/dev/null
assert_eq "smoke-e-tests-glob-matches" "0" "$?"
rm -rf "$SMOKE_E"

# ---- Mechanical assertion: workflow file exists at the canonical path ----
WORKFLOW="$PLUGIN_DIR/../.github/workflows/placeholder-leak-guard.yml"
if [ -f "$WORKFLOW" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("workflow-file-present (missing $WORKFLOW)")
fi
# Workflow targets main only (not sprint/* or dist).
if grep -qE 'branches:\s*\[main\]' "$WORKFLOW" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("workflow-targets-main-only (missing `branches: [main]` in $WORKFLOW)")
fi

# FINDING-31 fix: assert the workflow invokes the PRODUCTION-SCAN script, not
# this rule-test (which only exercises smoke fixtures). The CI gate is the
# production scan; without invoking it the workflow is a no-op.
PROD_SCAN="$PLUGIN_DIR/scripts/placeholder-leak-guard.sh"
if [ -f "$PROD_SCAN" ] && [ -x "$PROD_SCAN" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("production-scan-script-present-and-executable (missing/non-executable $PROD_SCAN)")
fi
if grep -qF "plugin/scripts/placeholder-leak-guard.sh" "$WORKFLOW" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("workflow-invokes-production-scan (workflow missing `plugin/scripts/placeholder-leak-guard.sh` invocation)")
fi
# The production scan runs the same scan_for_leaks logic — assert the
# script contains the load-bearing scan markers (defense-in-depth that the
# production scan does what the tests cover).
PROD_BODY=$(cat "$PROD_SCAN" 2>/dev/null)
case "$PROD_BODY" in
  *"find \"\$PLUGIN_DIR/docs/superpowers/migrations/entries\""*"-name 'NEXT-*.md'"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1))
     FAILED_CASES+=("prod-scan-does-step-1-find-NEXT-md (find pattern absent)") ;;
esac
case "$PROD_BODY" in
  *"grep -rln -E '<NEXT-(from|to)>' \"\$PLUGIN_DIR\""*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1))
     FAILED_CASES+=("prod-scan-does-step-2-grep-tokens (grep pattern absent)") ;;
esac

echo "placeholder-leak-guard-rules: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
