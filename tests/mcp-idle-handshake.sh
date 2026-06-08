#!/usr/bin/env bash
# Story 181 — i_am_truly_idle handshake + gated declare_idle + dual-clear resume_work.
# Drives the MCP server's CLI shims against a temp WOW_ROOT fixture (no hooks).
#
# Cases:
#  1 i_am_truly_idle round-trip writes .truly-idle.json[role]={idle,ts,pid}
#  2 declare_idle REFUSES (exit!=0) when not all of sd+pp+t confirmed; names offenders; no marker
#  3 declare_idle PASSES when sd+pp+t confirmed + alive + quiet; writes .nothing_to_do
#  4 declare_idle REFUSES on a WORK row (tool) since the idle mark; names that role
#  5 dead-pid: a confirmed role whose pid is dead -> declare_idle REFUSES, names it dead
#  6 resume_work clears BOTH .nothing_to_do AND .truly-idle.json
#  7 i_am_truly_idle idempotent (one entry per role; ts refreshes)
#  8 bad role rejected (exit!=0)
#  9 BLOCKER pin: a trailing `stop` row since idle does NOT count as activity -> still PASSES;
#    a `tool` row since idle DOES -> refuses
# 10 MAJOR pin: pid sourced from .activity.jsonl when --pid omitted (recorded pid == row claude_pid)

set -u
PASS=0; FAIL=0; FAILED=()
ck(){ local n="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$n (want '$e' got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="$SCRIPT_DIR/../mcp/claude-wow-server/server.py"
ERRF=$(mktemp)

# alive pids for sd/pp/t confirmations + one dead pid
sleep 300 & PSD=$!; sleep 300 & PPP=$!; sleep 300 & PT=$!
disown "$PSD" "$PPP" "$PT" 2>/dev/null || true   # silence job-control "Terminated" notices at cleanup
sh -c 'exit 0' & PDEAD=$!; wait "$PDEAD" 2>/dev/null
cleanup(){ kill "$PSD" "$PPP" "$PT" 2>/dev/null; rm -f "$ERRF"; }
trap cleanup EXIT

mk_root(){ local d; d=$(mktemp -d); mkdir -p "$d/implementations" "$d/.claude-plugin"; printf '{"name":"x"}' > "$d/.claude-plugin/plugin.json"; echo "$d"; }
# run a tool; echo its exit code; stderr -> $ERRF (warnings suppressed for clean assertions)
idle(){ local d="$1"; shift; PYTHONWARNINGS=ignore WOW_ROOT="$d" python3 "$SERVER" "$@" >/dev/null 2>"$ERRF"; echo $?; }
confirm(){ idle "$1" i_am_truly_idle --role "$2" --pid "$3" >/dev/null; }
marker(){ [ -f "$1/implementations/.nothing_to_do" ] && echo yes || echo no; }
jq_get(){ python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d$2)" "$1" 2>/dev/null; }

# Case 1: round-trip
D=$(mk_root); confirm "$D" senior-developer "$PSD"
ck "1-roundtrip-idle"  "True"   "$(jq_get "$D/implementations/.truly-idle.json" "['senior-developer']['idle']")"
ck "1-roundtrip-pid"   "$PSD"   "$(jq_get "$D/implementations/.truly-idle.json" "['senior-developer']['pid']")"
rm -rf "$D"

# Case 2: declare refuses when not all confirmed
# RED-WITHOUT: patch .red-without/181-declare-idle-gate.patch -> 2-refuse-exit
D=$(mk_root); confirm "$D" senior-developer "$PSD"
ck "2-refuse-exit"   "2"  "$(idle "$D" declare_idle)"
ck "2-names-pp"      "0"  "$(grep -cq 'pair-programmer' "$ERRF"; echo $?)"
ck "2-no-marker"     "no" "$(marker "$D")"
rm -rf "$D"

# Case 3: declare passes when all 3 confirmed + alive + quiet
D=$(mk_root); confirm "$D" senior-developer "$PSD"; confirm "$D" pair-programmer "$PPP"; confirm "$D" tester "$PT"
ck "3-pass-exit"     "0"   "$(idle "$D" declare_idle)"
ck "3-marker"        "yes" "$(marker "$D")"
rm -rf "$D"

# Case 4: work (tool) row since idle -> refuse, names sd
D=$(mk_root); confirm "$D" senior-developer "$PSD"; confirm "$D" pair-programmer "$PPP"; confirm "$D" tester "$PT"
printf '%s\n' "{\"ts\":\"2030-01-01T00:00:00Z\",\"claude_pid\":$PSD,\"role\":\"senior-developer\",\"type\":\"tool\"}" >> "$D/implementations/.activity.jsonl"
ck "4-work-refuse"   "2"  "$(idle "$D" declare_idle)"
ck "4-names-sd"      "0"  "$(grep -cq 'senior-developer has work activity' "$ERRF"; echo $?)"
rm -rf "$D"

# Case 5: dead pid -> refuse, names it dead
D=$(mk_root); confirm "$D" senior-developer "$PSD"; confirm "$D" pair-programmer "$PPP"; confirm "$D" tester "$PDEAD"
ck "5-deadpid-refuse" "2" "$(idle "$D" declare_idle)"
ck "5-names-dead"     "0" "$(grep -cq 'tester pid .* is dead' "$ERRF"; echo $?)"
rm -rf "$D"

# Case 6: resume_work clears BOTH
D=$(mk_root); confirm "$D" senior-developer "$PSD"; confirm "$D" pair-programmer "$PPP"; confirm "$D" tester "$PT"
idle "$D" declare_idle >/dev/null
ck "6-resume-exit"   "0"   "$(idle "$D" resume_work)"
ck "6-marker-gone"   "no"  "$(marker "$D")"
ck "6-truly-gone"    "no"  "$([ -f "$D/implementations/.truly-idle.json" ] && echo yes || echo no)"
rm -rf "$D"

# Case 7: idempotent (one entry per role)
D=$(mk_root); confirm "$D" senior-developer "$PSD"; confirm "$D" senior-developer "$PSD"
ck "7-idempotent" "1" "$(python3 -c "import json;print(len(json.load(open('$D/implementations/.truly-idle.json'))))" 2>/dev/null)"
rm -rf "$D"

# Case 8: bad role
D=$(mk_root)
ck "8-bad-role" "2" "$(idle "$D" i_am_truly_idle --role bogus --pid "$PSD")"
rm -rf "$D"

# Case 9 (BLOCKER pin): stop row since idle is NOT activity -> PASS; tool row IS -> refuse
D=$(mk_root); confirm "$D" senior-developer "$PSD"; confirm "$D" pair-programmer "$PPP"; confirm "$D" tester "$PT"
for p in "$PSD" "$PPP" "$PT"; do
  printf '%s\n' "{\"ts\":\"2030-01-01T00:00:00Z\",\"claude_pid\":$p,\"type\":\"stop\"}" >> "$D/implementations/.activity.jsonl"
done
ck "9-stop-still-passes" "0" "$(idle "$D" declare_idle)"
rm -f "$D/implementations/.nothing_to_do"
printf '%s\n' "{\"ts\":\"2030-06-06T00:00:00Z\",\"claude_pid\":$PSD,\"type\":\"tool\"}" >> "$D/implementations/.activity.jsonl"
ck "9-tool-refuses"      "2" "$(idle "$D" declare_idle)"
rm -rf "$D"

# Case 10 (MAJOR pin): pid sourced from .activity.jsonl when --pid omitted
D=$(mk_root)
printf '%s\n' "{\"ts\":\"2026-06-08T10:00:00Z\",\"claude_pid\":$PSD,\"role\":\"senior-developer\",\"type\":\"tool\"}" >> "$D/implementations/.activity.jsonl"
idle "$D" i_am_truly_idle --role senior-developer >/dev/null
ck "10-pid-from-activity" "$PSD" "$(jq_get "$D/implementations/.truly-idle.json" "['senior-developer']['pid']")"
rm -rf "$D"

echo; echo "mcp-idle-handshake: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
