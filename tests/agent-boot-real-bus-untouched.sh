#!/usr/bin/env bash
# Story 174 — meta-guard: an agent-booting / daemon-spawning run leaves the REAL
# shared bus + the REAL session-role-marker dir byte-unchanged AND spawns ZERO
# net-new wow-process daemons. Storm-prevention for BOTH facets:
#   facet 1 (bus-leak):    a WOW_ROOT-only emit must resolve to its fixture, not
#                          fall through to a foreign/real bus (resolver probe).
#   facet 2 (daemon-leak): a spawned wow-process daemon must be reaped, leaving
#                          zero net-new daemons (canary + delta gate).
#
# SAFETY (load-bearing):
#   * REAL_ROOT is the MAIN checkout, derived worktree-invariantly via
#     --git-common-dir (NEVER --show-toplevel), overridable by $WOW_GUARD_REAL_ROOT.
#     The daemon counter EXCLUDEs it, so live team daemons are never counted/killed.
#   * Every spawn here is pinned to a fresh mktemp fixture; the EXIT trap reaps by
#     the unique temp dir (the [ -n "$d" ] guard is mandatory — an empty pattern
#     would match a real daemon). It can never touch a real/other-project daemon.
#   * The guard reads (never writes) the real bus, and NEVER invokes run-all.sh /
#     run-all-inner.sh (it is auto-discovered by the self-check — nesting would
#     recurse + re-storm). It self-contains a canary instead.
#
# RED-WITHOUT (facet 1): .red-without/resolver-wow-root-first.patch
#   -> reverts the §1 resolver WOW_ROOT branch; the WOW_ROOT-only probe then lands
#      in the SENTINEL catch-all instead of its $FX fixture -> resolver-probe RED.
# RED-WITHOUT (facet 2): .red-without/daemon-reaping-canary.patch
#   -> reverts the canary's inline reap block; the canary's idle-monitor.py child
#      orphans -> count_nonmain_daemons increments -> daemon-delta RED. (The EXIT
#      trap still reaps it afterward, so no persistent leak even under the revert.)

set -u
PASS=0; FAIL=0; FAILED=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_SERVER="$PLUGIN_ROOT/mcp/claude-wow-server/server.py"
IDLE_MON="$PLUGIN_ROOT/scripts/wow-process/idle-monitor.sh"

# --- REAL_ROOT: worktree-invariant, plugin-agnostic (NOT --show-toplevel) ---
_gcd=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
MAIN_ROOT=$([ -n "${_gcd:-}" ] && dirname "$_gcd")
REAL_ROOT="${WOW_GUARD_REAL_ROOT:-${MAIN_ROOT:-}}"
if [ -z "${REAL_ROOT:-}" ] || [ ! -d "$REAL_ROOT/implementations" ]; then
  echo "agent-boot-real-bus-untouched: FATAL — REAL_ROOT misresolved (${REAL_ROOT:-unset}); set \$WOW_GUARD_REAL_ROOT"
  exit 2
fi
REAL_BUS="$REAL_ROOT/implementations/.message-bus.jsonl"
REAL_MARKER_DIR="$REAL_ROOT/.claude/.session-role-by-claude-pid"

_sha() { [ -f "$1" ] || { echo ""; return; }; shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
_lines() { [ -f "$1" ] || { echo 0; return; }; wc -l < "$1" 2>/dev/null | tr -d ' '; }
# Counts wow-process daemons NOT rooted at the main checkout (= test fixtures +
# any other-project daemons). EXCLUDE-real-root polarity is environment-
# independent; the DELTA gate is robust to STABLE foreign-project daemons (they
# appear in both before+after). NEVER an include-temp-prefix filter.
count_nonmain_daemons() {
  pgrep -f 'bus-tail[.]sh |idle-monitor[.]py|monitor-pipe[.]py' 2>/dev/null \
    | while read -r p; do ps -ww -o args= -p "$p" 2>/dev/null; done \
    | grep -vF "$REAL_ROOT" | grep -cE 'bus-tail[.]sh |idle-monitor[.]py|monitor-pipe[.]py' | tr -d ' '
}

# --- fixtures + the guard's own cleanup (canonical idiom; always reaps) ---
SENTINEL=$(mktemp -d); FX=$(mktemp -d); RW_TMP=$(mktemp -d)
GUARD_DIRS=("$SENTINEL" "$FX" "$RW_TMP")
SPAWNED=()
guard_cleanup() {
  for pid in "${SPAWNED[@]:-}"; do [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true; done
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    _left=
    for d in "${GUARD_DIRS[@]:-}"; do [ -n "$d" ] && pkill -f "$d" 2>/dev/null || true; done
    sleep 0.2
    for d in "${GUARD_DIRS[@]:-}"; do [ -n "$d" ] && pgrep -f "$d" >/dev/null 2>&1 && _left=1; done
    [ -z "$_left" ] && break
  done
  rm -rf "${GUARD_DIRS[@]}" 2>/dev/null || true
}
trap guard_cleanup EXIT INT TERM

# Snapshot the REAL bus + marker dir + non-main daemon count BEFORE.
RB_SHA0=$(_sha "$REAL_BUS"); RB_LN0=$(_lines "$REAL_BUS")
RM0=$(ls -1 "$REAL_MARKER_DIR" 2>/dev/null | sort | tr '\n' ',')
DAEMONS0=$(count_nonmain_daemons)

# ===== facet 1: resolver-only RED-WITHOUT probe =====
# A minimal emit relying SOLELY on the resolver honoring WOW_ROOT: WOW_ROOT=$FX
# (the fixture it should resolve to) while CLAUDE_PROJECT_DIR=$SENTINEL + cwd=$SENTINEL
# (the catch-all). Post-fix -> $FX; resolver reverted -> $SENTINEL. Never the real bus.
mkdir -p "$SENTINEL/implementations" "$SENTINEL/.claude-plugin" "$SENTINEL/.git" "$FX/implementations"
printf '{"name":"claude-wow","version":"0.0.0"}\n' > "$SENTINEL/.claude-plugin/plugin.json"
( cd "$SENTINEL" && WOW_ROOT="$FX" CLAUDE_PROJECT_DIR="$SENTINEL" CLAUDE_CONFIG_DIR="$SENTINEL/.claude" \
    python3 "$MCP_SERVER" bus_emit \
      --from senior-developer-20260101T000000-abcdef --to '*' --type hello \
      --payload-json '"red-without probe"' ) >/dev/null 2>&1 || true
FX_LN=$(_lines "$FX/implementations/.message-bus.jsonl")
SENT_LN=$(_lines "$SENTINEL/implementations/.message-bus.jsonl")
if [ "${FX_LN:-0}" -ge 1 ] && [ "${SENT_LN:-0}" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED+=("resolver-probe: WOW_ROOT-only emit must land in \$FX (got FX=$FX_LN SENTINEL=$SENT_LN)")
fi

# ===== facet 2: zero-net-new-daemon canary =====
# Spawn the REAL idle-monitor.sh wrapper over a sleep-forever stub python (so the
# child is reliably persistent + reparents on wrapper death, mirroring the leak).
mkdir -p "$RW_TMP/implementations/.wow-process" "$RW_TMP/wow-process" "$RW_TMP/.claude"
if [ -f "$IDLE_MON" ]; then
  cp "$IDLE_MON" "$RW_TMP/wow-process/idle-monitor.sh"
  cat > "$RW_TMP/wow-process/idle-monitor.py" <<'PYEOF'
import time
while True:
    time.sleep(1)
PYEOF
  # spawn the wrapper DIRECTLY (no subshell) so $! is the wrapper itself — killing
  # it stops the respawn loop. (A `( ... ) &` would make $! the subshell, leaving
  # the reparented wrapper alive to respawn.)
  CLAUDE_PROJECT_DIR="$RW_TMP" WOW_ROLE="manager" bash "$RW_TMP/wow-process/idle-monitor.sh" >/dev/null 2>&1 &
  SPAWNED+=("$!")
  disown 2>/dev/null || true   # drop from job table so the SIGKILL reap prints no "Killed" notice
  sleep 1.5   # let the wrapper spawn its python child
fi
# --- RED-WITHOUT-REAP-START (daemon-reaping-canary.patch reverts to here) ---
# Reap the canary: kill the wrapper FIRST (so it cannot respawn), then poll-sweep
# the fixture dir until no process referencing it remains.
for pid in "${SPAWNED[@]:-}"; do [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true; done
for _i in 1 2 3 4 5 6 7 8; do
  _l=
  [ -n "$RW_TMP" ] && pkill -f "$RW_TMP" 2>/dev/null || true
  sleep 0.25
  [ -n "$RW_TMP" ] && pgrep -f "$RW_TMP" >/dev/null 2>&1 && _l=1
  [ -z "$_l" ] && break
done
# --- RED-WITHOUT-REAP-END ---
# DELTA gate (poll-until-stable; generous ceiling, no tight fixed sleep).
DAEMONS1=$DAEMONS0
for _ in $(seq 1 40); do
  DAEMONS1=$(count_nonmain_daemons)
  [ "${DAEMONS1:-0}" -le "${DAEMONS0:-0}" ] && break
  sleep 0.2
done
if [ "${DAEMONS1:-0}" -le "${DAEMONS0:-0}" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED+=("daemon-leak: net-new wow-process daemons after canary (before=$DAEMONS0 after=$DAEMONS1)")
fi

# ===== real bus + marker dir UNCHANGED (both facets' standing proof) =====
RB_SHA1=$(_sha "$REAL_BUS"); RB_LN1=$(_lines "$REAL_BUS")
RM1=$(ls -1 "$REAL_MARKER_DIR" 2>/dev/null | sort | tr '\n' ',')
if [ "$RB_SHA0" = "$RB_SHA1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("REAL bus changed ($RB_LN0 -> $RB_LN1 lines) — a test leaked onto the shared bus"); fi
if [ "$RM0" = "$RM1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("REAL session-role-marker dir changed — a test wrote a marker into the real .claude/"); fi

echo ""
echo "agent-boot-real-bus-untouched: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
