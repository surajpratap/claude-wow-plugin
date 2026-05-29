#!/usr/bin/env bash
# slack-required-scopes-sync.sh (Story 095) — asserts bridge/slack/README.md's
# "Required bot-token scopes" table matches REQUIRED_SCOPES in
# src/bridge/required-scopes.ts exactly (set equality). ERROR + non-zero on drift.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
README="$ROOT/bridge/slack/README.md"
SCOPES_TS="$ROOT/bridge/slack/src/bridge/required-scopes.ts"

fail=0
[ -f "$README" ]   || { echo "ERROR: README not found: $README"; exit 1; }
[ -f "$SCOPES_TS" ] || { echo "ERROR: required-scopes.ts not found: $SCOPES_TS"; exit 1; }

# README: backticked scope tokens in the table rows between the Required heading
# and the next "## " heading (the Optional table is thus excluded).
readme_scopes=$(
  sed -n '/^## Required bot-token scopes/,/^## /p' "$README" \
    | grep -E '^\| `[a-z_]+:[a-z_.]+`' \
    | sed -E 's/^\| `([a-z_]+:[a-z_.]+)`.*/\1/' \
    | sort -u
)
# required-scopes.ts: the single-quoted entries inside the REQUIRED_SCOPES array.
# Anchor the start on the `export const REQUIRED_SCOPES … = [` line (not the comment
# that also names REQUIRED_SCOPES) and the end on the array's closing `];` line.
# Scope tokens can contain `.` (e.g., `users:read.email`).
code_scopes=$(
  sed -n '/^export const REQUIRED_SCOPES/,/^];/p' "$SCOPES_TS" \
    | grep -oE "'[a-z_]+:[a-z_.]+'" \
    | tr -d "'" \
    | sort -u
)

[ -n "$readme_scopes" ] || { echo "ERROR: parsed zero scopes from README table"; fail=1; }
[ -n "$code_scopes" ]   || { echo "ERROR: parsed zero scopes from REQUIRED_SCOPES"; fail=1; }

if [ "$readme_scopes" != "$code_scopes" ]; then
  echo "ERROR: required-scope drift — README table vs REQUIRED_SCOPES disagree:"
  diff <(echo "$readme_scopes") <(echo "$code_scopes") | sed 's/^/  /'
  fail=1
fi

if [ "$fail" -ne 0 ]; then echo "slack-required-scopes-sync: FAIL"; exit 1; fi
echo "slack-required-scopes-sync: ok ($(echo "$readme_scopes" | wc -l | tr -d ' ') scopes in sync)"
