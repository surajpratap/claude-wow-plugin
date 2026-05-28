#!/usr/bin/env bash
# Story 151 — directive prose hygiene guard.
#
# Role + doctrine files (commands/**.md) state instructions to an LLM in
# the present tense. The CHANGELOG (docs/superpowers/migrations/) is the
# place for "this was changed from X to Y" history; live directives must
# read "do this." This guard fails if directive files re-accumulate the
# banned framing.
#
# Patterns the guard rejects in commands/**.md:
#   (Story <NNN>)           — parenthetical story provenance
#   (FINDING-<NN>)          — parenthetical FINDING provenance
#   (vX.Y.Z)                — parenthetical version provenance
#   no ScheduleWakeup       — the specific tester-scheduler-nudge phrase
#   NO LONGER               — upper-case "was-X-now-Y" framing
#
# Scope: commands/**.md (role files + protocol + startups). Anything under
# docs/superpowers/migrations/ is the authoritative history and is exempt
# (and not scanned by this test).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CMDS="$ROOT/commands"

PATTERN='\(Story [0-9]+|\(FINDING-[0-9]+|\(v[0-9]+\.[0-9]+|no ScheduleWakeup|NO LONGER'

HITS=$(grep -rnE "$PATTERN" "$CMDS" 2>/dev/null || true)
COUNT=$([ -z "$HITS" ] && echo 0 || printf '%s\n' "$HITS" | wc -l | tr -d ' ')

echo "directive-prose-hygiene: scanning commands/**.md"
if [ "$COUNT" -eq 0 ]; then
  echo "directive-prose-hygiene: 0 banned-pattern hits"
  exit 0
fi

echo "directive-prose-hygiene: $COUNT banned-pattern hit(s) — directive files must read as plain present-tense instructions; move history to docs/superpowers/migrations/"
echo
printf '%s\n' "$HITS" | head -100
echo
echo "directive-prose-hygiene: FAIL"
exit 1
