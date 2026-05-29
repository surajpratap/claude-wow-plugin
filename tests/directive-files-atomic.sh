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

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
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
#   - commands/senior-developer.md: 100-225 (Plan file conventions block,
#     Version-bump convention, Trivial-tweak plan format, Implementation
#     rules' Version-literals bullet — all teach the placeholder convention).
#     Range shifted in v3.10.0 when startup blocks moved to _<role>-startup.md.
#   - commands/pair-programmer.md: 185-208 (Code-review version-literal
#     check enumerates the convention). Range widened in Story 106 (point
#     (4) Codex-arming preface quotes the literals); end bumped 205→208 in
#     Story 139 when the AC-count-section plan-shape-lint pointer was added
#     above this subsection (shifted the placeholder lines down ~3).
#   - commands/_agent-protocol.md: 905-942 (Story 106 — `## Sprint-mode
#     version placeholder convention` section is the canonical home of
#     both the inline-marker and codex-arming-preface texts; both quote
#     the `<NEXT-from>`/`<NEXT-to>` literals deliberately so codex /
#     external reviewers can see the placeholders being characterized as
#     intentional). Range shifted in Story 135 when the "Input schema vs
#     on-disk format" subsection was added higher in the file.
# Any other directive file matching the pattern = unconditional fail.

# Story 146: allowed <NEXT-*> example regions are detected via NEXT-PLACEHOLDER-EXAMPLE
# sentinel-comment pairs (a LINE-ORDERED state machine — NOT grep-START+grep-END+zip, which
# mis-pairs nested/unbalanced markers into widened regions), not hardcoded line ranges.
# Designated-files policy: only allowed=yes files may carry markers / an allowed region;
# a non-designated file fails on ANY marker OR any <NEXT-*> (preserves the old empty-range
# semantics — a marker can't loosen a file into having an allowed region).
# Pure status (no assert): echo "ok" + return 0 if clean; echo "FAIL:<reason>" + return 1.
# (Separated from the assertion so the fixture matrix below can test negative cases.)
_residual_status() {
  local file="$1" allowed="${2:-no}" markers n
  markers=$(grep -cE 'NEXT-PLACEHOLDER-EXAMPLE-(START|END)' "$file" 2>/dev/null | tr -d '[:space:]')
  if [ "$allowed" != "yes" ]; then
    [ "${markers:-0}" -ne 0 ] && { echo "FAIL:marker-in-nondesignated"; return 1; }
    n=$(grep -cE '<NEXT-(to|from)>' "$file" 2>/dev/null | tr -d '[:space:]')
    [ "${n:-0}" -ne 0 ] && { echo "FAIL:placeholder-no-region"; return 1; }
    echo ok; return 0
  fi
  # designated: line-ordered state machine — balanced START->END pairs only.
  local lineno=0 open_at=0 regions="" line
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno+1))
    case "$line" in
      *NEXT-PLACEHOLDER-EXAMPLE-START*) [ "$open_at" -ne 0 ] && { echo "FAIL:nested-start"; return 1; }; open_at=$lineno ;;
      *NEXT-PLACEHOLDER-EXAMPLE-END*)   [ "$open_at" -eq 0 ] && { echo "FAIL:end-without-start"; return 1; }; regions="$regions ${open_at}:${lineno}"; open_at=0 ;;
    esac
  done < "$file"
  [ "$open_at" -ne 0 ] && { echo "FAIL:eof-open"; return 1; }
  local ln r s e inside
  while IFS=: read -r ln _; do
    [ -z "$ln" ] && continue
    inside=0
    for r in $regions; do s=${r%%:*}; e=${r##*:}; if [ "$ln" -gt "$s" ] && [ "$ln" -lt "$e" ]; then inside=1; break; fi; done
    [ "$inside" -eq 0 ] && { echo "FAIL:placeholder-outside-region"; return 1; }
  done < <(grep -nE '<NEXT-(to|from)>' "$file" 2>/dev/null || true)
  echo ok; return 0
}
check_no_residual_placeholders() {
  local label="$1" file="$2" allowed="${3:-no}"
  assert_eq "${label}-no-residual-next-placeholders" "ok" "$(_residual_status "$file" "$allowed")"
}

check_no_residual_placeholders "manager"          "$COMMANDS_DIR/manager.md"          no
check_no_residual_placeholders "senior-developer" "$COMMANDS_DIR/senior-developer.md" yes
check_no_residual_placeholders "pair-programmer"  "$COMMANDS_DIR/pair-programmer.md"  yes
check_no_residual_placeholders "tester"           "$COMMANDS_DIR/tester.md"           no
check_no_residual_placeholders "slacker"          "$COMMANDS_DIR/slacker.md"          no
check_no_residual_placeholders "_agent-protocol"  "$COMMANDS_DIR/_agent-protocol.md"  yes

# Story 146: fixture matrix — proves _residual_status's marker semantics directly
# (the real-file calls above only exercise the happy path).
_ma_dir=$(mktemp -d)
_mk() { printf '%s\n' "$2" > "$_ma_dir/$1"; printf '%s' "$_ma_dir/$1"; }
_S='<!-- NEXT-PLACEHOLDER-EXAMPLE-START -->'; _E='<!-- NEXT-PLACEHOLDER-EXAMPLE-END -->'
_NF='<NEXT-from>'
assert_eq "146-a-inside-pair-ok"            "ok"  "$(_residual_status "$(_mk a "x
$_S
$_NF
$_E
y")" yes)"
assert_eq "146-b-outside-fails"             "FAIL:placeholder-outside-region" "$(_residual_status "$(_mk b "$_NF
$_S
ok
$_E")" yes)"
assert_eq "146-c-added-above-still-ok"      "ok"  "$(_residual_status "$(_mk c "newline1
newline2
$_S
$_NF
$_E")" yes)"
assert_eq "146-d-no-markers-fails"          "FAIL:placeholder-outside-region" "$(_residual_status "$(_mk d "just $_NF here")" yes)"
assert_eq "146-e1-nested-start"             "FAIL:nested-start"     "$(_residual_status "$(_mk e1 "$_S
$_S
$_E")" yes)"
assert_eq "146-e2-end-before-start"         "FAIL:end-without-start" "$(_residual_status "$(_mk e2 "$_E
$_S")" yes)"
assert_eq "146-e3-lone-start-eof-open"      "FAIL:eof-open"         "$(_residual_status "$(_mk e3 "$_S
content")" yes)"
assert_eq "146-e4-lone-end"                 "FAIL:end-without-start" "$(_residual_status "$(_mk e4 "$_E")" yes)"
assert_eq "146-f-leak-between-two-pairs"    "FAIL:placeholder-outside-region" "$(_residual_status "$(_mk f "$_S
$_NF
$_E
$_NF
$_S
$_NF
$_E")" yes)"
assert_eq "146-g-placeholder-on-start-line" "FAIL:placeholder-outside-region" "$(_residual_status "$(_mk g "$_S $_NF
$_E")" yes)"
assert_eq "146-h1-nondesignated-marker"     "FAIL:marker-in-nondesignated" "$(_residual_status "$(_mk h1 "$_S
$_E")" no)"
assert_eq "146-h2-nondesignated-placeholder" "FAIL:placeholder-no-region" "$(_residual_status "$(_mk h2 "stray $_NF")" no)"
assert_eq "146-i-nondesignated-clean"       "ok"  "$(_residual_status "$(_mk i "no placeholders here")" no)"
rm -rf "$_ma_dir"

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

# Each role's frozen-legacy startup file references the canonical doctrine
# file on its startup-read line. (Story 152: the new short
# _<role>-startup.md files invoke startup.sh; the doctrine references
# live in the frozen _<role>-startup-legacy.md companions for one release.
# Once legacy files are removed in the next minor, this test should
# assert the conventions directly on phase_bootstrap.sh / startup.sh.)
assert_match "manager-doctrine-file-ref"                 "$COMMANDS_DIR/_manager-startup-legacy.md"          'commands/_token-discipline\.md'
assert_match "senior-developer-doctrine-file-ref"        "$COMMANDS_DIR/_senior-developer-startup-legacy.md" 'commands/_token-discipline\.md'
assert_match "pair-programmer-doctrine-file-ref"         "$COMMANDS_DIR/_pair-programmer-startup-legacy.md"  'commands/_token-discipline\.md'
assert_match "tester-doctrine-file-ref"                  "$COMMANDS_DIR/_tester-startup-legacy.md"           'commands/_token-discipline\.md'
assert_match "slacker-doctrine-file-ref"                 "$COMMANDS_DIR/_slacker-startup-legacy.md"          'commands/_token-discipline\.md'

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
