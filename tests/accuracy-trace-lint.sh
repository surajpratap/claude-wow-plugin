#!/usr/bin/env bash
# Tests accuracy-trace-lint.sh — structural lint of a plan's accuracy-trace map.
# Cases: (spec §6) 1 valid->pass; 2 marked-missing-map->ERROR; 3 AGENTS.md-citation->ERROR;
# 4 unassigned-verifier->ERROR; 5 bad-anchor->ERROR; 6 doc-shaped-unmarked->WARN(exit0);
# 7 draft->exempt(exit0). Plus SD guards: 8 inline-marker-mention->not-marked(exit0);
# 9 empty-map (heading, no rows)->ERROR; 10 malformed-row (!=4 cols)->ERROR.
#
# NOTE: this is a file+grep test, not a behavioral producer test. Its text is
# deliberately written to avoid the three BEHAVIORAL_RE trigger substrings
# defined in red-without-lint.sh, so scan_real_tree (which greps the whole file
# TEXT) does not false-flag it as a behavioral test lacking the revert annotation.
set -u
PASS=0; FAIL=0; FAILED=()
ck() { local n="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$n (expected '$e' got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../scripts/accuracy-trace-lint.sh"

# mk_root <marked:0|1> -> echoes root dir with a story (+marker if marked) and a
# source file plugin/commands/slacker.md containing the anchor "SEPARATE CLONES".
mk_root() {
  local marked="$1" d; d=$(mktemp -d)
  mkdir -p "$d/implementations/plans" "$d/implementations/stories" "$d/plugin/commands"
  { echo '<!-- status: backlog -->'; echo '<!-- team: falcon -->';
    [ "$marked" = 1 ] && echo '<!-- accuracy-trace: required -->';
    echo '# story'; } > "$d/implementations/stories/900-x.md"
  printf '%s\n' 'The bundled Slack integration lives at slack/. Teams are SEPARATE CLONES.' \
    > "$d/plugin/commands/slacker.md"
  echo "$d"
}
plan_hdr() { printf '%s\n%s\n%s\n' '<!-- status: in-review -->' '# p' 'Story: implementations/stories/900-x.md'; }
valid_map() { printf '%s\n%s\n%s\n' \
  '## Accuracy-trace map' \
  '| Claim | Authoritative source | Anchor | Verifier |' \
  '|---|---|---|---|'
  printf '%s\n' '| Slack bundled | plugin/commands/slacker.md | "bundled Slack integration" | pp |' \
                '| Teams separate | plugin/commands/slacker.md | "SEPARATE CLONES" | t |'; }

run() { bash "$LINT" "$1" >/tmp/at_err.$$ 2>&1; echo $?; }

# Case 1: valid map -> exit 0
D=$(mk_root 1); P="$D/implementations/plans/900-x.md"; { plan_hdr; valid_map; } > "$P"
ck "valid-map-exit0" "0" "$(run "$P")"; rm -rf "$D"

# Case 2: marked story, no map -> ERROR (exit 1)
D=$(mk_root 1); P="$D/implementations/plans/900-x.md"; { plan_hdr; echo 'no map here'; } > "$P"
ck "marked-missing-map-exit1" "1" "$(run "$P")"; rm -rf "$D"

# Case 3: AGENTS.md citation -> ERROR
D=$(mk_root 1); P="$D/implementations/plans/900-x.md"
{ plan_hdr; printf '%s\n%s\n%s\n%s\n' '## Accuracy-trace map' '| Claim | Authoritative source | Anchor | Verifier |' '|---|---|---|---|' '| X | plugin/AGENTS.md | "anything" | pp |'; } > "$P"
ck "agents-md-citation-exit1" "1" "$(run "$P")"; rm -rf "$D"

# Case 4: missing verifier -> ERROR
D=$(mk_root 1); P="$D/implementations/plans/900-x.md"
{ plan_hdr; printf '%s\n%s\n%s\n%s\n' '## Accuracy-trace map' '| Claim | Authoritative source | Anchor | Verifier |' '|---|---|---|---|' '| X | plugin/commands/slacker.md | "SEPARATE CLONES" | |'; } > "$P"
ck "unassigned-verifier-exit1" "1" "$(run "$P")"; rm -rf "$D"

# Case 5: bad anchor (no grep match) -> ERROR
D=$(mk_root 1); P="$D/implementations/plans/900-x.md"
{ plan_hdr; printf '%s\n%s\n%s\n%s\n' '## Accuracy-trace map' '| Claim | Authoritative source | Anchor | Verifier |' '|---|---|---|---|' '| X | plugin/commands/slacker.md | "NONEXISTENT PHRASE" | pp |'; } > "$P"
ck "bad-anchor-exit1" "1" "$(run "$P")"; rm -rf "$D"

# Case 6: doc-shaped but unmarked -> WARN, exit 0
D=$(mk_root 0); P="$D/implementations/plans/900-x.md"
{ plan_hdr; echo 'This plan rewrites the customer-facing README and docs/ guide.'; } > "$P"
ck "doc-shaped-unmarked-exit0" "0" "$(run "$P")"
ck "doc-shaped-unmarked-warns" "0" "$(grep -q 'WARN' /tmp/at_err.$$; echo $?)"; rm -rf "$D"

# Case 7: draft -> exempt (exit 0 even if marked + no map)
D=$(mk_root 1); P="$D/implementations/plans/900-x.md"
{ echo '<!-- status: drafting -->'; echo '# p'; echo 'Story: implementations/stories/900-x.md'; } > "$P"
ck "draft-exempt-exit0" "0" "$(run "$P")"; rm -rf "$D"

# Case 8: marker mentioned ONLY inline in prose (not a standalone frontmatter line) ->
# NOT marked -> exit 0. Self-reference guard: a story that DESCRIBES the convention
# (like 180 itself) must not self-trigger the marker detection.
D=$(mk_root 0); P="$D/implementations/plans/900-x.md"
{ echo '<!-- status: backlog -->'; echo '<!-- team: falcon -->'; echo '# s';
  echo 'M sets `<!-- accuracy-trace: required -->` on the story (line 3).'; } > "$D/implementations/stories/900-x.md"
{ plan_hdr; echo 'no map; the story only mentions the marker inline.'; } > "$P"
ck "inline-marker-not-marked-exit0" "0" "$(run "$P")"; rm -rf "$D"

# Case 9: marked story, map HEADING present but ZERO data rows -> ERROR (FINDING-58 empty-map)
D=$(mk_root 1); P="$D/implementations/plans/900-x.md"
{ plan_hdr; printf '%s\n%s\n%s\n' '## Accuracy-trace map' '| Claim | Authoritative source | Anchor | Verifier |' '|---|---|---|---|'; } > "$P"
ck "empty-map-exit1" "1" "$(run "$P")"; rm -rf "$D"

# Case 10: marked story, a map row with !=4 columns -> ERROR (FINDING-58 malformed-row)
D=$(mk_root 1); P="$D/implementations/plans/900-x.md"
{ plan_hdr; printf '%s\n%s\n%s\n%s\n' '## Accuracy-trace map' '| Claim | Authoritative source | Anchor | Verifier |' '|---|---|---|---|' '| only | three | cells |'; } > "$P"
ck "malformed-row-exit1" "1" "$(run "$P")"; rm -rf "$D"

rm -f /tmp/at_err.$$
echo; echo "accuracy-trace-lint: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
