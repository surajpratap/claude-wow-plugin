#!/usr/bin/env bash
# Story 160 Layer E test — wow-block-rm-glob-non-manager.sh.
#
# 6-case matrix:
#   1. non-M + `rm path/*`              → blocked + remediation in reason
#   2. non-M + `rm -f specific-file`    → allowed (no glob)
#   3. non-M + `find … -delete`         → allowed (no rm)
#   4. M    + `rm path/*`               → allowed (M exempt)
#   5. non-M + `rm -rf "$WT/.claude/"*` → blocked
#   6. non-M + `rm "*"`                 → blocked (false-positive accepted; bias per plan)

set -u
PASS=0; FAIL=0; FAILED_CASES=()

REAL_WOW_LOCATE=$(command -v wow-locate 2>/dev/null || true)
if [ -z "$REAL_WOW_LOCATE" ]; then
  echo "SKIP: wow-locate not on PATH" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/scripts/hooks/wow-block-rm-glob-non-manager.sh"

run_hook() {
  local cmd="$1" role="$2"
  local STUB
  STUB=$(mktemp -d)
  cat > "$STUB/wow-locate" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "scripts/whats-my-role.sh" ]; then
  echo "$STUB/whats-my-role.sh"
  exit 0
fi
exec "$REAL_WOW_LOCATE" "\$@"
EOF
  chmod +x "$STUB/wow-locate"
  cat > "$STUB/whats-my-role.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "whats-my-role" ]; then echo "$role"; fi
EOF
  chmod +x "$STUB/whats-my-role.sh"
  printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')" \
    | PATH="$STUB:$PATH" bash "$HOOK"
  rm -rf "$STUB"
}

assert_blocked() {
  local name="$1" out="$2"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name should be BLOCKED (got '$out')")
  fi
}

assert_allowed() {
  local name="$1" out="$2"
  if [ -z "$out" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name should be ALLOWED (got '$out')")
  fi
}

# Case 1
OUT=$(run_hook 'rm path/*' senior-developer)
assert_blocked "non-M + rm glob" "$OUT"
if printf '%s' "$OUT" | jq -e '.reason | contains("nudge")' >/dev/null 2>&1; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("block reason should mention M-nudge bypass")
fi

# Case 2
OUT=$(run_hook 'rm -f path/specific-file' senior-developer)
assert_allowed "non-M + rm specific file (no glob)" "$OUT"

# Case 3
OUT=$(run_hook 'find ./tmp -type f -name "*.log" -delete' senior-developer)
assert_allowed "non-M + find -delete (no rm)" "$OUT"

# Case 4
OUT=$(run_hook 'rm path/*' manager)
assert_allowed "M + rm glob (M exempt)" "$OUT"

# Case 5
OUT=$(run_hook 'rm -rf "$WT/.claude/"*' tester)
assert_blocked "non-M + rm -rf .claude glob" "$OUT"

# Case 6 — false positive accepted per the bias-to-false-positives plan
OUT=$(run_hook 'rm "*"' senior-developer)
assert_blocked "non-M + rm \"*\" (false positive accepted)" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
