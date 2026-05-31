#!/usr/bin/env bash
# Story 172 — AC5 negative sentinel guard (the ONE sanctioned presence-grep).
#
# The opt-in usage auto-pause feature is MECHANISM-FIRST: the pause/resume
# protocol is carried just-in-time in the emitted directive payload (a bounded
# {pause,resume} value), NOT as standing prose in always-loaded md. This guard
# fails if the bus-type literals `usage-limit-pause` / `usage-limit-reset` ever
# appear in the always-loaded md set:
#   - commands/_agent-protocol.md (the protocol single-source)
#   - commands/*.md               (role + doctrine + startup files)
#   - AGENTS.md                   (plugin overview)
#
# docs/superpowers/migrations/ is the authoritative CHANGELOG and is EXEMPT
# (the migration entry names the literals deliberately) — it is not scanned.
#
# RED-WITHOUT: patch .red-without/no-usage-prose.patch -> token-present-in-md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CMDS="$ROOT/commands"

FORBIDDEN='usage-limit-pause|usage-limit-reset'

PASS=0
FAIL=0
FAILED=()

# Collect the always-loaded md set: every commands/*.md plus the plugin AGENTS.md.
# (commands/_agent-protocol.md is included by the commands/*.md glob.)
FILES=()
for f in "$CMDS"/*.md; do
  [ -f "$f" ] && FILES+=("$f")
done
[ -f "$ROOT/AGENTS.md" ] && FILES+=("$ROOT/AGENTS.md")

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "no-usage-prose-in-md: SKIP — no always-loaded md found under $CMDS"
  exit 0
fi

HITS=$(grep -rnE -- "$FORBIDDEN" "${FILES[@]}" 2>/dev/null || true)
if [ -z "$HITS" ]; then
  COUNT=0
else
  COUNT=$(printf '%s\n' "$HITS" | wc -l | tr -d ' ')
fi

if [ "$COUNT" -eq 0 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  FAILED+=("token-present-in-md ($COUNT hit(s) — pause/resume protocol must live in the directive payload, not standing md)")
fi

echo "no-usage-prose-in-md: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED[@]}"; do echo "  - $c"; done
  printf '%s\n' "$HITS" | head -50
  exit 1
fi
exit 0
