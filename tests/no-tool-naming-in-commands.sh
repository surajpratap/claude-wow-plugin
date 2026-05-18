#!/usr/bin/env bash
# Story 127 (FINDING-29) — enforce CLAUDE.md project-agnostic rule:
# `plugin/commands/*.md` must contain NO references to specific external
# tools (e.g. `codex`). Tool-specific configuration belongs in the
# consuming project's `AGENTS.md`, not in bundled plugin doctrine.

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
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$ROOT/commands"

# Banned tool tokens — extend this list if a new project-specific tool name
# ever leaks into plugin doctrine (the right home is the consuming repo's
# AGENTS.md, not here).
BANNED_TOOLS=(codex Codex)

for tool in "${BANNED_TOOLS[@]}"; do
  count=$(grep -rln "$tool" "$COMMANDS_DIR" 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "no-${tool}-in-plugin-commands" "0" "$count"
done

# Also assert the regression target is actually being scanned (sanity:
# COMMANDS_DIR exists, contains at least one *.md, the grep didn't no-op
# because the dir was empty).
md_count=$(ls "$COMMANDS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$md_count" -gt 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("commands-dir-not-empty (no *.md files in $COMMANDS_DIR — assertions would no-op)")
fi

echo "no-tool-naming-in-commands: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
