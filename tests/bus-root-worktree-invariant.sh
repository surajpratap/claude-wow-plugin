#!/usr/bin/env bash
# Story 184 — bus ROOT is worktree-invariant + bus-tail guards a non-main bus.
# From inside a linked worktree, bus-tail.sh --check-bus-root resolves the team
# bus via `git rev-parse --git-common-dir` (the MAIN repo), not --show-toplevel
# (the worktree). Uses a REAL git worktree fixture (actual git behavior, no mock).
#
# Cases:
#  c1 from worktree, --check-bus-root <main-bus>     → resolves to main, exit 0
#  c2 from worktree, --check-bus-root <worktree-bus> → EXIT_BUS_NOT_MAIN, non-zero
#  c3 WOW_ROOT=<main> + --check-bus-root <main-bus>  → exit 0 (override honored)

set -u
PASS=0; FAIL=0; FAILED=()
ck(){ local n="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$n (want '$e' got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BT="$ROOT/scripts/wow-process/bus-tail.sh"
[ -f "$BT" ] || { echo "bus-root-worktree-invariant: SKIP — $BT not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "bus-root-worktree-invariant: SKIP — git not found"; exit 0; }

# Real main repo + linked worktree, each with its own (distinct-inode) bus file.
D=$(mktemp -d); MAIN="$D/main"; WT="$D/wt"
mkdir -p "$MAIN/.claude-plugin" "$MAIN/implementations"
printf '{"name":"x"}\n' > "$MAIN/.claude-plugin/plugin.json"
( cd "$MAIN" && git init -q && git config user.email t@e && git config user.name t \
  && git add -A && git commit -qm init && git worktree add -q "$WT" -b wt184 ) >/dev/null 2>&1
printf 'main\n' > "$MAIN/implementations/.message-bus.jsonl"
mkdir -p "$WT/implementations"; printf 'worktree\n' > "$WT/implementations/.message-bus.jsonl"
MAIN_BUS="$MAIN/implementations/.message-bus.jsonl"
WT_BUS="$WT/implementations/.message-bus.jsonl"
cleanup(){ ( cd "$MAIN" && git worktree remove --force "$WT" >/dev/null 2>&1 ); rm -rf "$D"; }
trap cleanup EXIT

# bound each invocation — --check-bus-root must resolve+guard+exit (no tail loop);
# a timeout-kill (124) here is a failure, surfacing any regression to looping.
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"; command -v gtimeout >/dev/null 2>&1 && TO="gtimeout 10"

# c1: from the worktree, --check-bus-root resolves MAIN to the main-repo bus (inode-equal) + exit 0
# RED-WITHOUT: patch .red-without/184-resolution-show-toplevel.patch -> c1-resolution-inode
OUT=$( cd "$WT" && WOW_ROOT='' $TO bash "$BT" --check-bus-root "$MAIN_BUS" 2>/dev/null ); RC=$?
MAIN_RESOLVED=$(printf '%s\n' "$OUT" | sed -n 's/^MAIN //p')
ck "c1-resolution-exit0" "0" "$RC"
ck "c1-resolution-inode" "$(ls -i "$MAIN_BUS" 2>/dev/null | awk '{print $1}')" "$(ls -i "$MAIN_RESOLVED" 2>/dev/null | awk '{print $1}')"

# c2: from the worktree, --check-bus-root <worktree-bus> → guard fires
# RED-WITHOUT: patch .red-without/184-guard-removed.patch -> c2-guard-exit-nonzero
ERR=$( cd "$WT" && WOW_ROOT='' $TO bash "$BT" --check-bus-root "$WT_BUS" 2>&1 >/dev/null ); RC=$?
ck "c2-guard-exit-nonzero" "1" "$RC"
case "$ERR" in *EXIT_BUS_NOT_MAIN*) ck "c2-guard-diagnostic" "ok" "ok" ;; *) ck "c2-guard-diagnostic" "ok" "MISSING" ;; esac

# c3: WOW_ROOT override honored from any cwd
( cd "$D" && WOW_ROOT="$MAIN" $TO bash "$BT" --check-bus-root "$MAIN_BUS" ) >/dev/null 2>&1
ck "c3-wow-root-override" "0" "$?"

echo "bus-root-worktree-invariant: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
