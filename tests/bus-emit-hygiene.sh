#!/usr/bin/env bash
# Story 051 — bus-emit hygiene HARD RULE.
#
# Demonstrates the trap (inline single-quoted JSON with apostrophes /
# backticks fails silently) and verifies that the documented acceptable
# patterns (jq --arg, Write+jq-slurp via --argjson) produce valid JSONL
# preserving the original payload byte-for-byte.
#
# Cases:
# 1. inline single-quoted JSON containing an apostrophe → produces malformed JSON
# 2. jq --arg payload with apostrophe → valid JSONL, apostrophe preserved
# 3. Write-to-tempfile + jq --argjson with multi-line + apostrophes + backticks → valid JSONL, content preserved
# 4. inline single-quoted JSON containing backtick → bash command-substitutes the backtick
# 5. plain ASCII single-line payload → both inline AND jq --arg produce valid JSONL
# 6. heredoc tempfile + jq --argjson → canonical pattern produces valid JSONL

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

assert_neq() {
  local name="$1"; local expected_not="$2"; local actual="$3"
  if [ "$expected_not" != "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected NOT '$expected_not', got '$actual')")
  fi
}

DIR=$(mktemp -d)
BUS="$DIR/bus.jsonl"

# -----------------------------------------------------------------------------
# Case 1: inline single-quoted JSON with apostrophe → malformed JSON line
# -----------------------------------------------------------------------------
# Bash sees the apostrophe in "Code's" as a single-quote close. We construct
# the broken emit programmatically (not via a literal in this file, because
# *this* file is bash too). The realistic SD bug: agent typed an inline-quoted
# jq with a contraction in the payload. The result on the bus is malformed.
PAYLOAD_LITERAL="Claude Code's tool"
PARTIAL=$(printf "%s" "$PAYLOAD_LITERAL" | awk -F"'" '{print $1}')
echo "{\"payload\":\"$PARTIAL}" >> "$BUS"
LINE1=$(tail -1 "$BUS")
if echo "$LINE1" | jq -e . >/dev/null 2>&1; then
  VALID1="true"
else
  VALID1="false"
fi
assert_eq "case-1-inline-apostrophe-produces-malformed-json" "false" "$VALID1"

# -----------------------------------------------------------------------------
# Case 2: jq --arg payload with apostrophe → valid JSONL, apostrophe preserved
# -----------------------------------------------------------------------------
jq -nc --arg payload "$PAYLOAD_LITERAL" '{payload:$payload}' >> "$BUS"
LINE2=$(tail -1 "$BUS")
if echo "$LINE2" | jq -e . >/dev/null 2>&1; then
  VALID2="true"
else
  VALID2="false"
fi
assert_eq "case-2-jq-arg-apostrophe-valid-json" "true" "$VALID2"
ROUNDTRIP2=$(echo "$LINE2" | jq -r '.payload')
assert_eq "case-2-jq-arg-apostrophe-preserved" "$PAYLOAD_LITERAL" "$ROUNDTRIP2"

# -----------------------------------------------------------------------------
# Case 3: Write-to-tempfile + jq --argjson with multi-line apostrophes + backticks
# -----------------------------------------------------------------------------
TMPP="$DIR/payload3.json"
cat > "$TMPP" <<'EOF'
{"summary": "Line one with Claude Code's apostrophe.\nLine two with `backticks` for emphasis.\nLine three plain.", "details": ["nested", "fields"]}
EOF
jq -nc --argjson payload "$(cat "$TMPP")" '{payload:$payload}' >> "$BUS"
LINE3=$(tail -1 "$BUS")
if echo "$LINE3" | jq -e . >/dev/null 2>&1; then
  VALID3="true"
else
  VALID3="false"
fi
assert_eq "case-3-write-slurp-multi-line-valid-json" "true" "$VALID3"
SUM3=$(echo "$LINE3" | jq -r '.payload.summary')
EXPECTED3=$(jq -r '.summary' "$TMPP")
assert_eq "case-3-write-slurp-content-preserved" "$EXPECTED3" "$SUM3"

# -----------------------------------------------------------------------------
# Case 4: inline single-quoted JSON containing backtick → bash command-substitutes
# -----------------------------------------------------------------------------
# Realistic trap: agent typed `jq -nc "{payload:\"`whoami`\"}"` (double-quoted
# wrapping a backtick) — bash runs `whoami` instead of preserving the literal.
# Demonstrate by constructing an equivalent: a double-quoted body with a
# backtick that triggers command substitution.
WHO=$(whoami)
TRAP=$(echo "{\"payload\":\"`whoami`\"}")
TRAP_PAYLOAD=$(echo "$TRAP" | jq -r '.payload')
assert_eq "case-4-inline-backtick-substituted-by-bash" "$WHO" "$TRAP_PAYLOAD"

# Now the fix: emit the literal "`whoami`" string via --arg.
LITERAL='`whoami`'
jq -nc --arg payload "$LITERAL" '{payload:$payload}' >> "$BUS"
LINE4=$(tail -1 "$BUS")
ROUNDTRIP4=$(echo "$LINE4" | jq -r '.payload')
assert_eq "case-4-jq-arg-backtick-preserved-as-literal" "$LITERAL" "$ROUNDTRIP4"

# -----------------------------------------------------------------------------
# Case 5: plain ASCII single-line, no quotes/backticks — both inline + --arg work
# -----------------------------------------------------------------------------
# Inline acceptable case (the rule's documented exception).
echo '{"payload":"sprint dispatched 3 of 4"}' >> "$BUS"
LINE5A=$(tail -1 "$BUS")
if echo "$LINE5A" | jq -e . >/dev/null 2>&1; then VALID5A="true"; else VALID5A="false"; fi
assert_eq "case-5-inline-plain-ascii-valid-json" "true" "$VALID5A"

jq -nc --arg payload "sprint dispatched 3 of 4" '{payload:$payload}' >> "$BUS"
LINE5B=$(tail -1 "$BUS")
if echo "$LINE5B" | jq -e . >/dev/null 2>&1; then VALID5B="true"; else VALID5B="false"; fi
assert_eq "case-5-jq-arg-plain-ascii-valid-json" "true" "$VALID5B"

# -----------------------------------------------------------------------------
# Case 6: heredoc tempfile + jq --argjson — the canonical SD-prompt pattern
# -----------------------------------------------------------------------------
TMPP6="$DIR/payload6.json"
cat > "$TMPP6" <<'EOF'
{
  "summary": "M's retro digest",
  "items": [
    {"id": "051", "note": "bus-emit hygiene formalized — apostrophe trap"},
    {"id": "052", "note": "pp-checkpoint payload shape lint"}
  ],
  "version_at_close": "2.33.3"
}
EOF
jq -nc --arg ts "2026-05-03T00:00:00Z" --arg from "manager-test" --argjson payload "$(cat "$TMPP6")" \
  '{ts:$ts, from:$from, type:"retro-digest", payload:$payload}' >> "$BUS"
LINE6=$(tail -1 "$BUS")
if echo "$LINE6" | jq -e . >/dev/null 2>&1; then VALID6="true"; else VALID6="false"; fi
assert_eq "case-6-heredoc-argjson-canonical-valid-json" "true" "$VALID6"
ITEMS6=$(echo "$LINE6" | jq -r '.payload.items | length')
assert_eq "case-6-heredoc-argjson-payload-shape-preserved" "2" "$ITEMS6"

rm -rf "$DIR"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "bus-emit-hygiene: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
