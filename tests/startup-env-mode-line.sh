#!/usr/bin/env bash
# phase_env emits the current config mode at boot:
#   no config.json        → "env: mode=default"
#   config mode=ahod      → "env: mode=ahod"
# This is the restart-proof surfacing every role's startup doctrine keys on.

set -u
PASS=0; FAIL=0; FAILED=()
ck(){ local n="$1" e="$2" a="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$n (want '$e' got '$a')"); fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

mk(){ local d; d=$(mktemp -d); mkdir -p "$d/implementations"; printf 'falcon\n' > "$d/implementations/.my-team"; echo "$d"; }
run_env_phase(){
  # Source lib_emit + phase_env exactly as startup.sh does, run only phase_env.
  WOW_ROOT="$1" SCRIPT_DIR="$ROOT/scripts" bash -c '
    set -u
    . "$SCRIPT_DIR/startup/lib_emit.sh"
    . "$SCRIPT_DIR/startup/phase_env.sh"
    phase_env tester
  ' 2>/dev/null
}

# c1: no config.json → mode=default
D=$(mk)
OUT=$(run_env_phase "$D")
case "$OUT" in *"env: mode=default"*) ck "c1-default-line" "ok" "ok" ;; *) ck "c1-default-line" "ok" "MISSING ($OUT)" ;; esac
rm -rf "$D"

# c2: config.json mode=ahod → mode=ahod
D=$(mk)
printf '{"schema":1,"mode":"ahod"}\n' > "$D/implementations/config.json"
OUT=$(run_env_phase "$D")
case "$OUT" in *"env: mode=ahod"*) ck "c2-ahod-line" "ok" "ok" ;; *) ck "c2-ahod-line" "ok" "MISSING ($OUT)" ;; esac
rm -rf "$D"

echo "startup-env-mode-line: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then for c in "${FAILED[@]}"; do echo "  - $c"; done; exit 1; fi
exit 0
