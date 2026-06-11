#!/usr/bin/env bash
# wow-config.sh helper — get/set/del on implementations/config.json.
# Asserts: missing-file defaults, atomic create-on-set, .mode closed enum,
# nested paths, del, path-injection guard, worktree-invariant root, no tmp
# litter, unrelated-key preservation.

set -u
PASS=0; FAIL=0; FAILED=()
ck(){ local n="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$n (want '$e' got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WC="$ROOT/scripts/wow-config.sh"
[ -f "$WC" ] || { echo "wow-config: FAIL — $WC not found"; exit 1; }

mk(){ local d; d=$(mktemp -d); mkdir -p "$d/implementations"; echo "$d"; }

# c1: get .mode with no file → "default", exit 0
D=$(mk)
OUT=$(WOW_ROOT="$D" bash "$WC" get .mode); RC=$?
ck "c1-default-mode" "default" "$OUT"
ck "c1-exit0" "0" "$RC"
ck "c1-no-file-created" "absent" "$([ -f "$D/implementations/config.json" ] && echo present || echo absent)"
rm -rf "$D"

# c2: set .mode ahod → file created with schema+mode; get round-trips
D=$(mk)
WOW_ROOT="$D" bash "$WC" set .mode '"ahod"'
ck "c2-set-exit0" "0" "$?"
ck "c2-mode" "ahod" "$(jq -r '.mode' "$D/implementations/config.json")"
ck "c2-schema" "1" "$(jq -r '.schema' "$D/implementations/config.json")"
ck "c2-get" "ahod" "$(WOW_ROOT="$D" bash "$WC" get .mode)"

# c3: .mode closed enum — "sprint" rejected, file unchanged
WOW_ROOT="$D" bash "$WC" set .mode '"sprint"' 2>/dev/null; RC=$?
ck "c3-enum-rejected" "2" "$RC"
ck "c3-file-unchanged" "ahod" "$(jq -r '.mode' "$D/implementations/config.json")"

# c4: nested set/get round-trip + unrelated keys preserved
WOW_ROOT="$D" bash "$WC" set .ahod.assignments.senior-developer '"implementations/stories/001-x.md"'
ck "c4-nested-get" "implementations/stories/001-x.md" "$(WOW_ROOT="$D" bash "$WC" get .ahod.assignments.senior-developer)"
ck "c4-mode-preserved" "ahod" "$(WOW_ROOT="$D" bash "$WC" get .mode)"

# c5: del .ahod removes the key, mode survives
WOW_ROOT="$D" bash "$WC" del .ahod
ck "c5-del-exit0" "0" "$?"
ck "c5-ahod-gone" "" "$(WOW_ROOT="$D" bash "$WC" get .ahod)"
ck "c5-mode-survives" "ahod" "$(WOW_ROOT="$D" bash "$WC" get .mode)"

# c6: path-injection guard — bad paths exit 2
WOW_ROOT="$D" bash "$WC" get 'mode' 2>/dev/null;            ck "c6-no-leading-dot" "2" "$?"
WOW_ROOT="$D" bash "$WC" get '.mode; .x' 2>/dev/null;       ck "c6-jq-injection" "2" "$?"
WOW_ROOT="$D" bash "$WC" set '.a b' '"x"' 2>/dev/null;      ck "c6-space-in-path" "2" "$?"

# c7: non-JSON value rejected
WOW_ROOT="$D" bash "$WC" set .mode ahod 2>/dev/null;        ck "c7-bare-string-rejected" "2" "$?"

# c8: no tmp litter
TMP_COUNT=0; for f in "$D/implementations/"*tmp*; do [ -e "$f" ] && TMP_COUNT=$((TMP_COUNT+1)); done
ck "c8-no-tmp" "0" "$TMP_COUNT"
rm -rf "$D"

# c9: worktree invariance — from a linked worktree, writes land in MAIN
command -v git >/dev/null 2>&1 || { echo "wow-config: $PASS passed, $FAIL failed (worktree cases skipped — no git)"; [ "$FAIL" -gt 0 ] && exit 1; exit 0; }
W=$(mktemp -d); MAIN="$W/main"; WT="$W/wt"
mkdir -p "$MAIN/implementations"
( cd "$MAIN" && git init -q && git config user.email t@e && git config user.name t \
  && git add -A 2>/dev/null; git commit -qm init --allow-empty && git worktree add -q "$WT" -b wtx ) >/dev/null 2>&1
( cd "$WT" && WOW_ROOT='' bash "$WC" set .mode '"ahod"' )
ck "c9-main-written" "ahod" "$(jq -r '.mode' "$MAIN/implementations/config.json" 2>/dev/null)"
ck "c9-worktree-clean" "absent" "$([ -f "$WT/implementations/config.json" ] && echo present || echo absent)"
( cd "$MAIN" && git worktree remove --force "$WT" >/dev/null 2>&1 ); rm -rf "$W"

echo "wow-config: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
