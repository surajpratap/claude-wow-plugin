#!/usr/bin/env bash
# Story 047 — peers never call AskUserQuestion (lint test).
#
# Greps each peer file for `AskUserQuestion` mentions and classifies each
# occurrence by surrounding context. Allowed contexts:
#   - prohibition strings ("never call AskUserQuestion", "Never use", etc.)
#   - M-behavior-description strings ("M relays via AskUserQuestion", etc.)
# Disallowed: any un-contextualized mention.
#
# M is OUT of scope (M's role IS to call AskUserQuestion).

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

# Classify a peer file: emit "ok" or "finding:<line-snippet>".
# Approach: extract every line containing AskUserQuestion, check each
# against the allowed-context regex set. If any line fails all allowed
# patterns, return finding.
classify_file() {
  local file="$1"
  local lines
  lines=$(grep -nE 'AskUserQuestion' "$file" 2>/dev/null || true)
  [ -z "$lines" ] && { echo "ok"; return; }

  local IFS=$'\n'
  for line in $lines; do
    # Strip line-number prefix
    local body="${line#*:}"
    local lower
    # Lowercase + strip backticks so patterns match "the askuserquestion flow"
    # whether or not it's wrapped in backticks in the source.
    lower=$(echo "$body" | tr '[:upper:]' '[:lower:]' | tr -d '`')

    # Allowed: any explicit prohibition / hard-rule context
    case "$lower" in
      *"never call"*|*"never use"*|*"do not call"*|*"do not use"*|*"do not directly"*|*"prohibition"*|*"hard rule"*|*"never emit"*|*"not prohibited"*|*"prohibited"*) continue ;;
    esac

    # Allowed: M-behavior descriptions — the line attributes the action to M
    case "$lower" in
      *" m relays"*|*" m emits"*|*" m presents"*|*" m invokes"*|*" m routes"*|*" m uses"*|*" m calls"*|*" m decides"*|*" m wraps"*|*" m asks"*|*" m writes"*|*" m parses"*|*" m will"*|*" m may"*|*" m should"*|*" m's "*) continue ;;
      *"m relays"*|*"m emits"*|*"m presents"*|*"m invokes"*|*"m routes"*|*"m calls"*|*"m decides"*|*"m wraps"*|*"m asks"*|*"m writes"*|*"m parses"*|*"m's askuserquestion"*|*"via m's"*|*"escalate via"*|*"to m via"*|*"through m"*|*"relayed via"*|*"via m"*) continue ;;
    esac

    # Allowed: discussing AskUserQuestion as a UX / verification target / tool
    case "$lower" in
      *"askuserquestion flow"*|*"askuserquestion ux"*|*"askuserquestion tool"*|*"askuserquestion-driven"*|*"askuserquestion prompt"*|*"the askuserquestion (rule|hard rule|behavior|window)"*|*"always-askuserquestion"*) continue ;;
    esac

    echo "finding: $body"
    return
  done
  echo "ok"
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Case 1-4: each peer file should classify as "ok".
for role in pair-programmer senior-developer tester slacker; do
  RESULT=$(classify_file "$ROOT/commands/$role.md")
  assert_eq "case-${role}-classification" "ok" "$RESULT"
done

# Case 5: synthetic positive — un-contextualized mention triggers finding.
DIR=$(mktemp -d)
cat > "$DIR/fake-peer.md" <<'EOF'
# Fake peer

When you need a decision, call AskUserQuestion with the prompt and options.
EOF
RESULT=$(classify_file "$DIR/fake-peer.md")
case "$RESULT" in
  finding:*) assert_eq "case-5-synthetic-finding" "yes" "yes" ;;
  *) assert_eq "case-5-synthetic-finding" "yes" "no (got: $RESULT)" ;;
esac
rm -rf "$DIR"

# Case 6: M file is OUT of scope. Manager.md SHOULD have many AskUserQuestion
# mentions (it's M's job). Test does NOT scan it. Verify by NOT testing it
# and asserting manager.md indeed contains AskUserQuestion (sanity check —
# confirms our scope exclusion would matter).
M_HAS_AUQ=$(grep -c 'AskUserQuestion' "$ROOT/commands/manager.md" 2>/dev/null || echo 0)
M_OUT_OF_SCOPE=$([ "$M_HAS_AUQ" -gt 0 ] && echo "yes" || echo "no")
assert_eq "case-6-m-has-askuserquestion-confirming-scope-exclusion-rationale" "yes" "$M_OUT_OF_SCOPE"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "peers-never-askuserquestion: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
