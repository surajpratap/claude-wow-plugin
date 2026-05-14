#!/usr/bin/env bash
# Story 062 — atomicity gate for directive files in commands/.
#
# Per AC #8 + AC #3: each directive file must have ZERO occurrences of known
# stale patterns in non-migration-table content. The migration table in
# commands/manager.md (lines starting with "   | " inside its bounds) is
# canonical changelog by design and exempt — historical rows reference paths
# that were deleted or renamed in subsequent stories.
#
# Stale patterns:
#   1. `>> .message-bus` — raw direct bus writes (replaced by mcp__claude-wow__bus_emit)
#   2. `bash scripts/bus-emit.sh` — deleted bash wrapper (Story 062)
#   3. `senior-dev-` (with hyphen + a-z) — legacy agent-ID prefix
#      (replaced with `senior-developer-` in Story 059)
#
# Files checked (one case each):
#   - commands/manager.md
#   - commands/senior-developer.md
#   - commands/pair-programmer.md
#   - commands/tester.md
#   - commands/slacker.md
#   - commands/_agent-protocol.md

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_zero() {
  local name="$1"; local count="$2"; local context="$3"
  if [ "$count" -eq 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected 0, got $count $context)")
  fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMANDS_DIR="$REPO_ROOT/commands"

# Filter out lines that belong to a migration-table row.
# Migration-table rows in commands/manager.md start with three spaces then a
# pipe: "   | ". Other files have no migration table, so the filter is a
# no-op there.
strip_migration_rows() {
  grep -vE '^   \| '
}

# Count occurrences of a pattern in a file's non-migration-row content.
# Uses extended-regex; pass the pattern as already-properly-escaped.
count_pattern() {
  local file="$1"; local pat="$2"
  strip_migration_rows < "$file" | grep -cE "$pat" || true
}

# Per-file checks. Each case asserts each of the 3 stale patterns is absent
# in non-migration-row content.
check_file() {
  local label="$1"; local file="$2"
  local n_raw_bus n_bus_emit_sh n_legacy_sd

  n_raw_bus=$(count_pattern "$file" '>>.*\.message-bus\.jsonl')
  n_bus_emit_sh=$(count_pattern "$file" 'bash scripts/bus-emit\.sh')
  # Match `senior-dev` NOT followed by `eloper` (the suffix that would make
  # it `senior-developer`). Catches both `senior-dev` bare (in role enums)
  # AND `senior-dev-X` (legacy agent-ID prefix). Awk because BRE/ERE has no
  # negative-lookahead.
  n_legacy_sd=$(strip_migration_rows < "$file" \
                | awk '
                  {
                    n = 0
                    s = $0
                    while (match(s, /senior-dev/)) {
                      after_idx = RSTART + RLENGTH
                      after = substr(s, after_idx, 6)
                      if (after !~ /^eloper/) n++
                      s = substr(s, after_idx)
                    }
                    total += n
                  }
                  END { print total + 0 }
                ')

  assert_zero "${label}-no-raw-bus-writes"   "$n_raw_bus"     "raw bus-write lines"
  assert_zero "${label}-no-bus-emit-sh-refs" "$n_bus_emit_sh" "bash bus-emit.sh refs"
  assert_zero "${label}-no-legacy-sd-prefix" "$n_legacy_sd"   "legacy senior-dev-* refs"
}

check_file "manager"          "$COMMANDS_DIR/manager.md"
check_file "senior-developer" "$COMMANDS_DIR/senior-developer.md"
check_file "pair-programmer"  "$COMMANDS_DIR/pair-programmer.md"
check_file "tester"           "$COMMANDS_DIR/tester.md"
check_file "slacker"          "$COMMANDS_DIR/slacker.md"
check_file "_agent-protocol"  "$COMMANDS_DIR/_agent-protocol.md"

# Story 063: regression case — `<NEXT-to>` / `<NEXT-from>` placeholders should
# only appear in legitimate convention-explanation contexts (SD's "Plan file
# conventions" / "Version-bump convention" sections, PP's "Code-review
# version-literal check" subsection). Anywhere else = leftover placeholder
# from a sprint-merge-bump.sh wrapper that didn't substitute (auto-merge
# revoked 2026-05-04; placeholders escaping into prose-like contexts
# leak into shipped role files).
#
# Allowed line-ranges (inclusive). Update when the legitimate sections move:
#   - commands/senior-developer.md: 170-300 (Plan file conventions block,
#     Version-bump convention, Trivial-tweak plan format, Implementation
#     rules' Version-literals bullet — all teach the placeholder convention)
#   - commands/pair-programmer.md: 270-290 (Code-review version-literal
#     check enumerates the convention)
# Any other directive file matching the pattern = unconditional fail.

check_no_residual_placeholders() {
  local label="$1"; local file="$2"; local allow_start="$3"; local allow_end="$4"
  local total=0
  while IFS=: read -r linenum _; do
    [ -z "$linenum" ] && continue
    if [ -n "$allow_start" ] && [ "$linenum" -ge "$allow_start" ] && [ "$linenum" -le "$allow_end" ]; then
      continue  # inside legitimate convention-teaching block
    fi
    total=$((total+1))
  done < <(grep -nE '<NEXT-(to|from)>' "$file" 2>/dev/null || true)
  assert_zero "${label}-no-residual-next-placeholders" "$total" "stray <NEXT-to>/<NEXT-from> outside allowed range"
}

check_no_residual_placeholders "manager"          "$COMMANDS_DIR/manager.md"          ""    ""
check_no_residual_placeholders "senior-developer" "$COMMANDS_DIR/senior-developer.md" 170   300
check_no_residual_placeholders "pair-programmer"  "$COMMANDS_DIR/pair-programmer.md"  270   300
check_no_residual_placeholders "tester"           "$COMMANDS_DIR/tester.md"           ""    ""
check_no_residual_placeholders "slacker"          "$COMMANDS_DIR/slacker.md"          ""    ""
check_no_residual_placeholders "_agent-protocol"  "$COMMANDS_DIR/_agent-protocol.md"  ""    ""

# Story 066: assert PP role file documents the upstream code-review plugin
# haiku dedup false-positive + cites the upstream-issue draft path. Without
# this awareness, PP may mis-triage the silent-skip case as a bug or fabricate
# triage events for a workflow that didn't fire.
assert_match() {
  local name="$1"; local file="$2"; local pattern="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (no match for /$pattern/ in $file)")
  fi
}
assert_match "pp-haiku-dedup-note-present" "$COMMANDS_DIR/pair-programmer.md" 'haiku dedup false-positive|haiku pre-check'
assert_match "pp-haiku-dedup-spec-cite" "$COMMANDS_DIR/pair-programmer.md" 'docs/superpowers/specs/2026-05-07-upstream-claude-code-plugins-haiku-dedup-issue\.md'

# Story 069: every role file has a "Token discipline" section + references the
# canonical doctrine path + uses the payload field name. T's role file is
# additionally checked for the post-impl rename + zero fswatch references.

assert_no_match() {
  local name="$1"; local file="$2"; local pattern="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (unexpected match for /$pattern/ in $file)")
  else
    PASS=$((PASS+1))
  fi
}

# Each role file references the canonical doctrine file on its startup-read
# line.
assert_match "manager-doctrine-file-ref"                 "$COMMANDS_DIR/manager.md"          'commands/_token-discipline\.md'
assert_match "senior-developer-doctrine-file-ref"        "$COMMANDS_DIR/senior-developer.md" 'commands/_token-discipline\.md'
assert_match "pair-programmer-doctrine-file-ref"         "$COMMANDS_DIR/pair-programmer.md"  'commands/_token-discipline\.md'
assert_match "tester-doctrine-file-ref"                  "$COMMANDS_DIR/tester.md"           'commands/_token-discipline\.md'
assert_match "slacker-doctrine-file-ref"                 "$COMMANDS_DIR/slacker.md"          'commands/_token-discipline\.md'

# T's role file: zero fswatch references + no "Reacting to events" header +
# "Testability concerns (post-impl)" rename present.
assert_no_match "tester-no-fswatch"                      "$COMMANDS_DIR/tester.md"           'fswatch'
assert_no_match "tester-no-reacting-to-events-header"    "$COMMANDS_DIR/tester.md"           '^# Reacting to events'
assert_match   "tester-testability-post-impl-rename"     "$COMMANDS_DIR/tester.md"           '^# Testability concerns \(post-impl\)'

# Amendment-4 (mechanical-over-prose): WOW-core role files do NOT carry a
# `# Token discipline` section header. The doctrine ships project-agnostic;
# per-role concrete examples live project-side at
# implementations/learnings/<role>.md. Each role file's only token-discipline
# footprint is the one-line startup-read step. Catches drift back to verbose
# in-role-file prose.
assert_no_match "manager-no-token-discipline-section"          "$COMMANDS_DIR/manager.md"          '^# Token discipline'
assert_no_match "senior-developer-no-token-discipline-section" "$COMMANDS_DIR/senior-developer.md" '^# Token discipline'
assert_no_match "pair-programmer-no-token-discipline-section"  "$COMMANDS_DIR/pair-programmer.md"  '^# Token discipline'
assert_no_match "tester-no-token-discipline-section"           "$COMMANDS_DIR/tester.md"           '^# Token discipline'
assert_no_match "slacker-no-token-discipline-section"          "$COMMANDS_DIR/slacker.md"          '^# Token discipline'

echo "directive-files-atomic: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
