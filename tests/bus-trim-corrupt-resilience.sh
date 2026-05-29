#!/usr/bin/env bash
# Story 119 — M's Phase-1 bus trim must skip a corrupt line without wedging.
# Per `_manager-startup.md` Phase 1 step 5: `jq -c -R 'fromjson? | select(...)'`.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP_DOC="$ROOT/commands/_manager-startup-legacy.md"

# ---- Case (a): the doctrine line matches the expected pattern ----
if grep -qF "jq -c -R --arg cutoff" "$STARTUP_DOC" && \
   grep -qF "fromjson?" "$STARTUP_DOC" && \
   grep -qE 'type=="?object"?' "$STARTUP_DOC"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("a-doctrine-pattern (missing one of: jq -c -R --arg cutoff / fromjson? / type==object)")
fi

# ---- Case (b): end-to-end — seed a bus with valid+corrupt lines, trim, assert ----
D=$(mktemp -d)
BUS="$D/bus.jsonl"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CUTOFF=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
AGED=$(date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)
{
  printf '{"ts":"%s","from":"a","to":"*","type":"x","payload":{"keep":1}}\n' "$NOW"
  printf '{"ts":"%s","from":"b","to":"*","type":"x","payload":{"keep":2}}\n' "$NOW"
  printf '{not valid json — torn write fragment\n'
  printf '{"ts":"%s","from":"c","to":"*","type":"x","payload":{"keep":0}}\n' "$AGED"
} > "$BUS"

# Run the actual trim command — same as `_manager-startup.md` Phase 1 step 5.
jq -c -R --arg cutoff "$CUTOFF" 'fromjson? | select(type=="object" and .ts >= $cutoff)' "$BUS" > "$BUS.tmp" && mv "$BUS.tmp" "$BUS"
RC=$?
assert_eq "b-trim-rc0" "0" "$RC"

# Two newer valid lines kept; the corrupt line and aged line gone ⇒ exactly 2 lines.
NLINES=$(wc -l < "$BUS" | tr -d ' ')
assert_eq "b-line-count-2" "2" "$NLINES"
# Confirm content survived (the two `keep` values).
if grep -q '"keep":1' "$BUS" && grep -q '"keep":2' "$BUS"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("b-content-preserved (newer valid lines missing)")
fi
# Confirm the corrupt line and the aged-valid line are gone.
if grep -q 'torn write fragment' "$BUS"; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("b-corrupt-line-dropped (corrupt line survived trim)")
else
  PASS=$((PASS+1))
fi
if grep -q '"keep":0' "$BUS"; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("b-aged-line-dropped (aged valid line survived trim)")
else
  PASS=$((PASS+1))
fi
rm -rf "$D"

# ---- Case (c): regression — old jq -c form WOULD have failed on the corrupt
# fixture. (Mechanical proof of why the change is necessary.) ----
D2=$(mktemp -d)
BUS2="$D2/bus.jsonl"
{
  printf '{"ts":"%s","from":"a","type":"x"}\n' "$NOW"
  printf 'not valid json\n'
} > "$BUS2"
# Old form exits non-zero on the corrupt line.
jq -c --arg cutoff "$CUTOFF" 'select(.ts >= $cutoff)' "$BUS2" > "$BUS2.tmp" 2>/dev/null
OLD_RC=$?
# New form exits 0 even with corrupt line.
jq -c -R --arg cutoff "$CUTOFF" 'fromjson? | select(type=="object" and .ts >= $cutoff)' "$BUS2" > "$BUS2.new.tmp" 2>/dev/null
NEW_RC=$?
# Old should be NON-zero (wedge); new should be 0 (skip).
if [ "$OLD_RC" -ne 0 ] && [ "$NEW_RC" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("c-regression-proof (old_rc=$OLD_RC new_rc=$NEW_RC; expected old!=0 and new==0)")
fi
rm -rf "$D2"

echo "bus-trim-corrupt-resilience: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
