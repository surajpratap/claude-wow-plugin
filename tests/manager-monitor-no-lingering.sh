#!/usr/bin/env bash
# manager-monitor-no-lingering.sh — completeness guard for the daemon rename.
#
# After the daemon was renamed to manager-monitor, the OLD daemon name (matched
# case-insensitively by the regex below) must NOT appear in the plugin's
# PRODUCTION surface — `commands/`, `scripts/` (incl. the load-bearing
# `scripts/startup/` arming + `scripts/hooks/`), `mcp/`, `bridge/`. A hit there
# is a missed reference, and a missed reference may be LOAD-BEARING (e.g. the
# startup monitor-arming), so fail loudly.
#
# Scope rationale: the scan is PRODUCTION-ONLY. `tests/` is excluded because
# tests legitimately reference the renamed-away name — regression guards and
# RED-WITHOUT revert fixtures assert the old name is gone / restore it on
# purpose. Stale-PATH `.red-without/*.patch` files are caught independently by
# `red-without-lint.sh` (a patch that no longer applies fails the lint). The
# frozen migration changelog (`docs/superpowers/migrations/**`) is also exempt.
#
# The search pattern is a regex (no verbatim old-name literal), so this file
# does not flag itself even though it lives under tests/.
#
# RED-WITHOUT: patch .red-without/186-lingering-ref.patch -> manager-monitor-no-lingering: FAIL
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Regex (NOT a literal): old daemon name with hyphen OR underscore, any case.
PAT='idle[-_]monitor'

HITS=""
for d in commands scripts mcp bridge; do
  [ -d "$ROOT/$d" ] || continue
  found=$(grep -rniE "$PAT" "$ROOT/$d" 2>/dev/null || true)
  [ -n "$found" ] && HITS="${HITS}${found}\n"
done

if [ -n "$HITS" ]; then
  echo "manager-monitor-no-lingering: FAIL — stale old-daemon-name references in production code:"
  printf '%b' "$HITS"
  exit 1
fi
echo "manager-monitor-no-lingering: PASS — no stale references in commands/ scripts/ mcp/ bridge/"
exit 0
