#!/usr/bin/env bash
# MCP server AHOD auto-injects in handle_bus_emit:
#   ahod-kickoff           → read-ahod-doctrine to "*" ALWAYS (+ token-discipline + learnings)
#   story-created          → read-ahod-doctrine mirroring `to` ONLY when config mode=ahod;
#                            read-skill (writing-plans) mirrors `to` in ahod mode
#   compaction-occurred    → read-ahod-doctrine mirroring `to` ONLY when mode=ahod
#   ahod-ack / ahod-stand-down → accepted by the type enum, no extra inject
# Default-mode purity: without config.json (or mode=default) behavior is unchanged.
#
# RED-WITHOUT: patch .red-without/ahod-doctrine-inject-disabled.patch -> a1-kickoff-4-lines

set -u
PASS=0; FAIL=0; FAILED=()
ck(){ local n="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$n (want '$e' got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"
SENDER="manager-20260611T090000-aabbcc"
OWNER="tester-20260611T090001-ddeeff"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations/.agents"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo '{}' > "$d/implementations/.agents/$OWNER.json"
  echo "$d"
}
set_mode(){ printf '{"schema":1,"mode":"%s"}\n' "$2" > "$1/implementations/config.json"; }
bus(){ echo "$1/implementations/.message-bus.jsonl"; }
types(){ jq -r '.type' "$(bus "$1")" | paste -sd, -; }

# a: ahod-kickoff → 4 lines: original + read-token-discipline + read-learnings + read-ahod-doctrine
PA=$(mk_project); set_mode "$PA" ahod
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PA" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"ahod-kickoff\",\"to\":\"*\",\"payload\":{\"doctrine\":\"commands/_ahod-doctrine.md\"}}" >/dev/null
ck "a1-kickoff-4-lines" "4" "$(wc -l < "$(bus "$PA")" | tr -d ' ')"
ck "a2-types" "ahod-kickoff,read-token-discipline,read-learnings,read-ahod-doctrine" "$(types "$PA")"
AH=$(jq -c 'select(.type=="read-ahod-doctrine")' "$(bus "$PA")")
ck "a3-ahod-to-star"  "*" "$(echo "$AH" | jq -r '.to')"
ck "a4-ahod-path"     "commands/_ahod-doctrine.md" "$(echo "$AH" | jq -r '.payload.path')"
ck "a5-ahod-from"     "$SENDER" "$(echo "$AH" | jq -r '.from')"
rm -rf "$PA"

# a': kickoff injects even without config.json (kickoff implies the mode)
PA2=$(mk_project)
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PA2" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"ahod-kickoff\",\"to\":\"*\"}" >/dev/null
ck "a6-kickoff-no-config-4-lines" "4" "$(wc -l < "$(bus "$PA2")" | tr -d ' ')"
rm -rf "$PA2"

# b: story-created in ahod mode to exact owner → 5 lines; doctrine + skill injects mirror `to`
PB=$(mk_project); set_mode "$PB" ahod
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PB" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"story-created\",\"to\":\"$OWNER\",\"payload\":{\"ref\":\"implementations/stories/001-x.md\",\"ahod\":true}}" >/dev/null
ck "b1-ahod-story-5-lines" "5" "$(wc -l < "$(bus "$PB")" | tr -d ' ')"
ck "b2-doctrine-mirrors-to" "$OWNER" "$(jq -r 'select(.type=="read-ahod-doctrine") | .to' "$(bus "$PB")")"
ck "b3-skill-mirrors-to"    "$OWNER" "$(jq -r 'select(.type=="read-skill") | .to' "$(bus "$PB")")"
ck "b4-skill-still-writing-plans" "superpowers:writing-plans" "$(jq -r 'select(.type=="read-skill") | .payload.skill' "$(bus "$PB")")"
rm -rf "$PB"

# c: story-created mode=default → 4 lines, no ahod inject, skill to SD-glob (today's behavior)
PC=$(mk_project); set_mode "$PC" default
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PC" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}" >/dev/null
ck "c1-default-story-4-lines" "4" "$(wc -l < "$(bus "$PC")" | tr -d ' ')"
ck "c2-no-ahod-inject" "" "$(jq -r 'select(.type=="read-ahod-doctrine") | .type' "$(bus "$PC")")"
ck "c3-skill-to-sd-glob" "senior-developer-*" "$(jq -r 'select(.type=="read-skill") | .to' "$(bus "$PC")")"
rm -rf "$PC"

# d: story-created with NO config.json → identical to default mode
PD=$(mk_project)
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PD" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"story-created\",\"to\":\"senior-developer-*\",\"payload\":{\"ref\":\"x\"}}" >/dev/null
ck "d1-no-config-4-lines" "4" "$(wc -l < "$(bus "$PD")" | tr -d ' ')"
rm -rf "$PD"

# e: compaction-occurred mode=ahod → 3 lines (original + learnings + ahod), mirrors exact id
PE=$(mk_project); set_mode "$PE" ahod
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PE" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$OWNER\",\"type\":\"compaction-occurred\",\"to\":\"$OWNER\",\"payload\":{\"role\":\"tester\"}}" >/dev/null
ck "e1-compaction-ahod-3-lines" "3" "$(wc -l < "$(bus "$PE")" | tr -d ' ')"
ck "e2-doctrine-mirrors-exact" "$OWNER" "$(jq -r 'select(.type=="read-ahod-doctrine") | .to' "$(bus "$PE")")"
rm -rf "$PE"

# f: compaction-occurred mode=default → 2 lines (original + learnings)
PF=$(mk_project); set_mode "$PF" default
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PF" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$OWNER\",\"type\":\"compaction-occurred\",\"to\":\"$OWNER\",\"payload\":{\"role\":\"tester\"}}" >/dev/null
ck "f1-compaction-default-2-lines" "2" "$(wc -l < "$(bus "$PF")" | tr -d ' ')"
rm -rf "$PF"

# g: ahod-ack + ahod-stand-down pass the enum, 1 line each, no injects
PG=$(mk_project); set_mode "$PG" ahod
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PG" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$OWNER\",\"type\":\"ahod-ack\",\"to\":\"manager-*\",\"payload\":{\"role\":\"tester\"}}" >/dev/null
WOW_ROOT='' CLAUDE_PROJECT_DIR="$PG" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"ahod-stand-down\",\"to\":\"*\",\"payload\":{\"reason\":\"revoked\"}}" >/dev/null
ck "g1-ack-standdown-2-lines" "2" "$(wc -l < "$(bus "$PG")" | tr -d ' ')"
rm -rf "$PG"

echo "mcp-server-ahod-auto-inject: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
