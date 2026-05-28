#!/usr/bin/env bash
# Story 073 — PreToolUse hook that blocks direct writes to .message-bus.jsonl.
# 9 spec cases + PP-observation #1 (MultiEdit) + #2 (cat bus > other allow) +
# jq-missing graceful fallback.

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

assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/scripts/hooks/wow-forbid-direct-bus-write.sh"

run_hook() {
  ERR=$(echo "$1" | bash "$HOOK" 2>&1 >/dev/null)
  EXIT=$?
}

BUS_PATH='/x/implementations/.message-bus.jsonl'

run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi >> $BUS_PATH\"}}"
assert_eq        "case-1-bash-append-deny-exit-2"  "2"                          "$EXIT"
assert_contains  "case-1-bash-append-deny-stderr"  "mcp__claude-wow__bus_emit"  "$ERR"

run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"tee -a $BUS_PATH <<< hi\"}}"
assert_eq "case-2-bash-tee-deny-exit-2" "2" "$EXIT"

run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i 's|x|y|' $BUS_PATH\"}}"
assert_eq "case-3-bash-sed-i-deny-exit-2" "2" "$EXIT"

run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf hi > $BUS_PATH\"}}"
assert_eq "case-4-bash-printf-redirect-deny-exit-2" "2" "$EXIT"

run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BUS_PATH\"}}"
assert_eq "case-5-write-tool-deny-exit-2" "2" "$EXIT"

run_hook "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$BUS_PATH\"}}"
assert_eq "case-6-edit-tool-deny-exit-2" "2" "$EXIT"

run_hook "{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$BUS_PATH\"}}"
assert_eq "case-6b-multiedit-tool-deny-exit-2" "2" "$EXIT"

run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $BUS_PATH\"}}"
assert_eq "case-7-bash-cat-allow-exit-0" "0" "$EXIT"

run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $BUS_PATH > /tmp/copy\"}}"
assert_eq "case-7b-bash-cat-bus-to-other-allow-exit-0" "0" "$EXIT"

run_hook '{"tool_name":"Bash","tool_input":{"command":"echo hi >> /other/path"}}'
assert_eq "case-8-bash-append-other-allow-exit-0" "0" "$EXIT"

run_hook '{"tool_name":"Write","tool_input":{"file_path":"/other/path"}}'
assert_eq "case-9-write-other-allow-exit-0" "0" "$EXIT"

# Story 148 — bus READS are allowed in any position; only writes-to-bus block.
run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq . $BUS_PATH | tail\"}}"
assert_eq "case-11-jq-read-piped-allow-exit-0" "0" "$EXIT"

# Demonstrator: a bus read after an UNRELATED redirect elsewhere in the command.
# The old greedy regex blocked this (false positive); the fix allows it.
run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo start > /tmp/log; jq . $BUS_PATH\"}}"
assert_eq "case-12-read-after-unrelated-redirect-allow-exit-0" "0" "$EXIT"

run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"grep hi $BUS_PATH && echo done > /tmp/x\"}}"
assert_eq "case-13-read-plus-trailing-unrelated-write-allow-exit-0" "0" "$EXIT"

run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git rev-parse --show-toplevel 2>/dev/null || pwd; jq . $BUS_PATH\"}}"
assert_eq "case-14-read-after-stderr-redirect-allow-exit-0" "0" "$EXIT"

NOJQ=$(mktemp -d)
# Symlink bash into a clean dir; that dir is the ENTIRE PATH so jq cannot
# resolve. Empty PATH would break the `bash $HOOK` invocation itself.
ln -s "$(command -v bash)" "$NOJQ/bash"
ERR10=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi >> $BUS_PATH\"}}" \
  | PATH="$NOJQ" "$NOJQ/bash" "$HOOK" 2>&1 >/dev/null)
EXIT10=$?
assert_eq        "case-10-jq-missing-exit-0"     "0"              "$EXIT10"
assert_contains  "case-10-jq-missing-stderr"     "jq not on PATH" "$ERR10"
rm -rf "$NOJQ"

echo "forbid-direct-bus-write: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
