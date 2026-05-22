#!/usr/bin/env bash
# Story 143 — idle-monitor counts a peer busy when a bg-spawn OUTLIVES its
# spawning stop-episode (Story-098's current-episode-only check read idle while
# the bg still ran). Time-bounded: busy iff the most-recent bg-spawn (any
# episode) is <= BG_BUSY_MAX_AGE_SECONDS old; future-ts (clock skew) ignored.
#
# Determinism via WOW_IDLE_NOW_EPOCH. The genuine cross-episode repro needs an
# INTERVENING `stop` (else the bg-spawn is in the SAME episode as the final stop
# and Story-098 already handled it). The cap=0 override is the provable guard:
# with cap=0 the cross-episode case flips to idle (== old current-episode logic
# for this fixture, which has NO bg-spawn in its current episode), proving the
# busy verdict comes solely from the cross-episode time-bound bg-spawn.

set -u
PASS=0; FAIL=0; FAILED=()
assert_eq(){ local n="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$n (expected '$e', got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="$ROOT/scripts/wow-process/idle-monitor.py"
[ -f "$PY" ] || { echo "idle-monitor-bg-cross-episode: SKIP — $PY not found"; exit 0; }

NOW=1747922400  # fixed epoch ~2026-05-22T14:00:00Z (WOW_IDLE_NOW_EPOCH)
iso(){ python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
# row <offset-seconds-from-NOW> <type>  (negative offset = past)
row(){ printf '{"ts":"%s","claude_pid":%d,"role":"manager","type":"%s"}\n' "$(iso $((NOW + $1)))" "$$" "$2"; }
mk(){ local d; d=$(mktemp -d); mkdir -p "$d/.claude-plugin" "$d/.claude/.session-role-by-claude-pid" "$d/implementations"; echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"; echo manager > "$d/.claude/.session-role-by-claude-pid/$$"; cat > "$d/implementations/.activity.jsonl"; echo "$d"; }
run(){ local cap="${2:-1200}"; CLAUDE_PROJECT_DIR="$1" WOW_IDLE_NOW_EPOCH="$NOW" WOW_BG_BUSY_MAX_AGE_SECONDS="$cap" python3 "$PY" --check-predicate 2>/dev/null; }

# (a) cross-episode, within window: bg-spawn -300 -> STOP -> prompt_in -> tool -> stop(latest)
#     current episode (after the first stop) has NO bg-spawn -> old logic=idle; new=busy.
A=$( { row -300 bg-spawn; row -290 stop; row -200 prompt_in; row -100 tool; row -10 stop; } | mk )
assert_eq "a-cross-episode-within-window-BUSY" "busy" "$(run "$A")"
# provable guard: with cap=0 the only busy driver (the time-bound bg-spawn) vanishes -> idle
# (== Story-098 current-episode behavior for this fixture; proves it's a genuine repro, not a no-op)
assert_eq "a-cap0-flips-idle (old-predicate-equivalent / red-green)" "idle" "$(run "$A" 0)"
rm -rf "$A"

# (b) cross-episode, expired: bg-spawn -1300 (> cap) -> stop -> prompt_in -> stop -> idle (recovery)
B=$( { row -1300 bg-spawn; row -1290 stop; row -200 prompt_in; row -10 stop; } | mk )
assert_eq "b-cross-episode-expired-IDLE" "idle" "$(run "$B")"
rm -rf "$B"

# (c) same-episode within window (Story-098 still works): bg-spawn -60 -> stop(latest) -> busy
C=$( { row -60 bg-spawn; row -10 stop; } | mk )
assert_eq "c-same-episode-within-window-BUSY" "busy" "$(run "$C")"
rm -rf "$C"

# (d) no bg-spawn: prompt_in -> stop -> idle
D=$( { row -100 prompt_in; row -10 stop; } | mk )
assert_eq "d-no-bg-spawn-IDLE" "idle" "$(run "$D")"
rm -rf "$D"

# (e) future-ts skew guard: bg-spawn +600 (ahead of now) -> stop -> idle (must NOT count busy)
E=$( { row 600 bg-spawn; row -10 stop; } | mk )
assert_eq "e-future-ts-skew-IDLE" "idle" "$(run "$E")"
rm -rf "$E"

echo "idle-monitor-bg-cross-episode: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
