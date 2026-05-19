#!/usr/bin/env bash
# Story 115 / FINDING-31 — production scan for unresolved `<NEXT>` placeholders.
#
# Invoked by .github/workflows/placeholder-leak-guard.yml on PRs targeting `main`.
# Scope is `plugin/` ONLY (the consumer-facing tree); root-level source-repo
# artifacts (implementations/plans/, AGENTS.md, source specs) legitimately quote
# the placeholder convention in their bodies and are out of scope.
#
# This is the PRODUCTION scan. The companion test
# `plugin/tests/placeholder-leak-guard-rules.sh` exercises the rule LOGIC against
# tmp fixtures (so `tests/run-all.sh` on sprint branches doesn't false-fail).
#
# Failure modes:
#   1. Any `plugin/docs/superpowers/migrations/entries/NEXT-*.md` file present
#      means `sprint-merge-bump.sh` / `sprint-finalize.sh` didn't run before merge.
#   2. Any literal `<NEXT-from>` / `<NEXT-to>` token in `plugin/` OUTSIDE the
#      allow-list.
#
# Exit 0 on clean tree; exit 1 on a leak.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ALLOW_PATTERNS=(
  "commands/_agent-protocol.md"
  "commands/senior-developer.md"
  "commands/pair-programmer.md"
  "commands/manager.md"
  "commands/_retro-doctrine.md"
  "scripts/sprint-merge-bump.sh"
  "scripts/sprint-finalize.sh"
  "scripts/placeholder-leak-guard.sh"
  "docs/superpowers/migrations/manager-schema-migrations.md"
  "tests/*.sh"
)

is_allowed() {
  local rel="$1"
  for pat in "${ALLOW_PATTERNS[@]}"; do
    # shellcheck disable=SC2053
    if [[ "$rel" == $pat ]]; then
      return 0
    fi
  done
  return 1
}

rc=0

# Step 1: NEXT-*.md entry files.
entries=$(find "$PLUGIN_DIR/docs/superpowers/migrations/entries" -maxdepth 1 -type f -name 'NEXT-*.md' 2>/dev/null)
if [ -n "$entries" ]; then
  echo "[leak-guard] NEXT-<id>.md entry file(s) found on main — sprint-merge-bump.sh / sprint-finalize.sh didn't run before merge:" >&2
  echo "$entries" | sed 's|^|  |' >&2
  rc=1
fi

# Step 2: <NEXT-from>/<NEXT-to> tokens outside the allow-list.
hits=$(grep -rln -E '<NEXT-(from|to)>' "$PLUGIN_DIR" 2>/dev/null || true)
leaked=""
while IFS= read -r match; do
  [ -z "$match" ] && continue
  rel="${match#$PLUGIN_DIR/}"
  if ! is_allowed "$rel"; then
    leaked="${leaked}${rel}"$'\n'
  fi
done <<< "$hits"

if [ -n "$leaked" ]; then
  echo "[leak-guard] <NEXT-from>/<NEXT-to> token(s) found in plugin/ outside the allow-list:" >&2
  echo -n "$leaked" | sed 's|^|  |' >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "[leak-guard] OK — no unresolved placeholders in plugin/"
fi
exit $rc
