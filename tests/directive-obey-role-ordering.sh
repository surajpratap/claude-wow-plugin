#!/usr/bin/env bash
# Story 172 §4 — doctrine-shape, SENTINEL-SAFE role-ordering guard.
#
# Proves the BOUNDED directive-obey rule is wired into every consumer's
# dispatch in the right place (closes "fixture-obeys != real-roles-obey"):
#   - Each of the 4 PEER role files (senior-developer / pair-programmer /
#     tester / slacker) references the directive-obey rule BEFORE its own
#     absorb-unknown fallback (dispatch ORDER — so a directive is never
#     silently absorbed as an unknown type).
#   - The MANAGER file is EXEMPT: it carries an explicit M-EXEMPT statement
#     and does NOT instruct M to halt on a directive.
#
# Checks dispatch ORDER + role-asymmetry — NOT the `usage-limit-*` literal
# (which the no-md-prose sentinel forbids). The directive rule names the
# closed {pause,resume} set generically.

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
CMD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/commands"

# A directive-obey reference: a line that mentions a `directive` AND both
# members of the closed set (pause + resume) — sentinel-safe, names no
# usage-limit-* literal. Returns the FIRST matching 1-based line number, or "".
directive_line() {
  local f="$1"
  grep -niE 'directive' "$f" | grep -iE 'pause' | grep -iE 'resume' | head -1 | cut -d: -f1
}

# The absorb-unknown fallback line (the per-role phrasings).
absorb_line() {
  local f="$1"
  grep -niE 'absorb (other|silently)|other (types|message types) (→|->|:) absorb|→ absorb; don' "$f" \
    | head -1 | cut -d: -f1
}

# ---- 4 PEER roles: directive rule BEFORE absorb-unknown ----
for role in senior-developer pair-programmer tester slacker; do
  f="$CMD_DIR/$role.md"
  if [ ! -f "$f" ]; then
    assert_eq "$role-file-exists" "yes" "no"
    continue
  fi
  dl=$(directive_line "$f")
  al=$(absorb_line "$f")
  if [ -z "$dl" ]; then
    assert_eq "$role-has-directive-rule" "yes" "no"
    continue
  fi
  if [ -z "$al" ]; then
    assert_eq "$role-has-absorb-fallback" "yes" "no"
    continue
  fi
  if [ "$dl" -lt "$al" ]; then
    assert_eq "$role-directive-before-absorb" "ordered" "ordered"
  else
    assert_eq "$role-directive-before-absorb" "ordered" "directive@$dl NOT before absorb@$al"
  fi
done

# ---- MANAGER: EXEMPT (explicit), and NOT told to halt on a directive ----
MF="$CMD_DIR/manager.md"
if [ ! -f "$MF" ]; then
  assert_eq "manager-file-exists" "yes" "no"
else
  # An explicit M-exempt statement keyed to the directive rule.
  if grep -niE 'M is EXEMPT|MANAGER is EXEMPT|manager .* exempt' "$MF" | grep -iqE 'directive'; then
    assert_eq "manager-explicitly-exempt" "yes" "yes"
  else
    assert_eq "manager-explicitly-exempt" "yes" "no"
  fi
  # M is NOT instructed to HALT on a directive (no peer-style halt-on-pause line
  # in the manager file). The exempt line says "never halts" — assert no line
  # tells M to HALT its loop on a directive/pause.
  if grep -niE 'directive' "$MF" | grep -iE 'pause' | grep -iqE 'HALT (all )?(work|your loop)'; then
    # Allow the exempt phrasing that explicitly NEGATES halting ("never halts",
    # "Do NOT halt", "but never halts M"). A bare HALT instruction is the bug.
    if grep -niE 'directive' "$MF" | grep -iqE 'never halt|do not halt|not halt|EXEMPT'; then
      assert_eq "manager-not-told-to-halt" "exempt-phrasing" "exempt-phrasing"
    else
      assert_eq "manager-not-told-to-halt" "exempt-phrasing" "bare-HALT-instruction-present"
    fi
  else
    assert_eq "manager-not-told-to-halt" "exempt-phrasing" "exempt-phrasing"
  fi
fi

echo "directive-obey-role-ordering: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
