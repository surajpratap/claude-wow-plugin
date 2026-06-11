#!/usr/bin/env bash
# AHOD reroute of the pr-created → code-review-request auto-inject:
#   mode=ahod    → inject `to` = the pr-created emitter (exact agent ID)
#   mode=default → inject `to` = pair-programmer-* (today's behavior)
#   no config    → pair-programmer-*
#   sprint integration-branch suppression beats the reroute (no inject at all)
#
# RED-WITHOUT: patch .red-without/ahod-code-review-reroute-disabled.patch -> a3-to-emitter

set -u
PASS=0; FAIL=0; FAILED=()
ck(){ local n="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$n (want '$e' got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_CALL="$ROOT/tests/fixtures/mcp-call.sh"
SENDER="tester-20260611T090001-ddeeff"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  touch "$d/implementations/.message-bus.jsonl"
  echo "$d"
}
set_mode(){ printf '{"schema":1,"mode":"%s"}\n' "$2" > "$1/implementations/config.json"; }
bus(){ echo "$1/implementations/.message-bus.jsonl"; }
emit_pr(){ WOW_ROOT='' CLAUDE_PROJECT_DIR="$1" bash "$MCP_CALL" bus_emit \
  "{\"from\":\"$SENDER\",\"type\":\"pr-created\",\"to\":\"manager-*\",\"payload\":{\"pr\":7,\"url\":\"u\",\"base\":\"${2:-main}\"}}" >/dev/null; }

# a: mode=ahod → inject routed to the emitter
PA=$(mk_project); set_mode "$PA" ahod
emit_pr "$PA"
ck "a1-two-lines" "2" "$(wc -l < "$(bus "$PA")" | tr -d ' ')"
ck "a2-type" "code-review-request" "$(sed -n 2p "$(bus "$PA")" | jq -r '.type')"
ck "a3-to-emitter" "$SENDER" "$(sed -n 2p "$(bus "$PA")" | jq -r '.to')"
ck "a4-payload-carried" "7" "$(sed -n 2p "$(bus "$PA")" | jq -r '.payload.pr_created_payload.pr')"
rm -rf "$PA"

# b: mode=default → pair-programmer-*
PB=$(mk_project); set_mode "$PB" default
emit_pr "$PB"
ck "b1-to-pp-glob" "pair-programmer-*" "$(sed -n 2p "$(bus "$PB")" | jq -r '.to')"
rm -rf "$PB"

# c: no config.json → pair-programmer-*
PC=$(mk_project)
emit_pr "$PC"
ck "c1-to-pp-glob" "pair-programmer-*" "$(sed -n 2p "$(bus "$PC")" | jq -r '.to')"
rm -rf "$PC"

# d: sprint integration-branch suppression still wins (even with mode=ahod)
PD=$(mk_project); set_mode "$PD" ahod
mkdir -p "$PD/implementations/sprints/s1"
printf '{"status":"active","integration_branch":"integration/s1"}\n' > "$PD/implementations/sprints/s1/manifest.json"
emit_pr "$PD" "integration/s1"
ck "d1-suppressed-one-line" "1" "$(wc -l < "$(bus "$PD")" | tr -d ' ')"
rm -rf "$PD"

echo "mcp-server-ahod-code-review-reroute: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
