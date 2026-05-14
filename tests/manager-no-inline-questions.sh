#!/usr/bin/env bash
# Story 013 / heuristic regression guard.
#
# Greps commands/manager.md for prose patterns where M is shown asking
# the human a plain-text question, outside any AskUserQuestion code
# fence or context. Goal: catch regressors that re-introduce the
# open-ended-question exception in M's prompt.
#
# Patterns (start of a markdown bullet OR start of a line):
#   "Should I "
#   "Want me to "
#   "Do you prefer "
#   "Would you like "
#   "Shall I "
#   "Can I "
#
# Exemptions (kept loose to avoid false positives):
#   - Lines inside fenced code blocks (between ``` markers).
#   - Lines that contain the literal string "AskUserQuestion" anywhere
#     (so AskUserQuestion examples + cross-references don't trip the
#     heuristic).
#
# Bench-test: temporarily insert a line like
#     - Should I bump the version?
# at the top of commands/manager.md, run this script, confirm exit 1
# with the line number reported. Revert.
#
# Exit 0 if no hits; exit 1 with diagnostic if any hits.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/commands/manager.md"

if [ ! -f "$TARGET" ]; then
  echo "FATAL: missing $TARGET" >&2
  exit 2
fi

PATTERNS=(
  "Should I "
  "Want me to "
  "Do you prefer "
  "Would you like "
  "Shall I "
  "Can I "
)

HITS=0
FAILED_LINES=()
in_fence=0
lineno=0

while IFS= read -r line; do
  lineno=$((lineno + 1))
  # Toggle fenced-code-block state on lines starting with ```.
  case "$line" in
    '```'*) in_fence=$((1 - in_fence)); continue ;;
  esac
  [ "$in_fence" -eq 1 ] && continue

  # Exemption: line mentions AskUserQuestion → not counted.
  case "$line" in
    *"AskUserQuestion"*) continue ;;
  esac

  # Strip leading whitespace + bullet markers to anchor at start of prose.
  stripped="${line#"${line%%[![:space:]]*}"}"  # ltrim
  case "$stripped" in
    '- '*|'* '*|'+ '*) stripped="${stripped:2}" ;;
    '> '*) stripped="${stripped:2}" ;;
  esac

  for p in "${PATTERNS[@]}"; do
    case "$stripped" in
      "$p"*)
        HITS=$((HITS + 1))
        FAILED_LINES+=("line $lineno: pattern '$p' — $line")
        break
        ;;
    esac
  done
done < "$TARGET"

if [ "$HITS" -ne 0 ]; then
  echo "FAIL: $HITS plain-text-question pattern(s) found in commands/manager.md (Story 013 hard rule)" >&2
  for l in "${FAILED_LINES[@]}"; do
    echo "  - $l" >&2
  done
  exit 1
fi

echo "OK — no plain-text-question patterns found in commands/manager.md (Story 013 hard rule)"
exit 0
