#!/usr/bin/env bash
# Story 077 — each role-command file references its own
# `commands/_<role>-startup.md` boot procedure (the explicit Read
# instruction that replaced the UserPromptSubmit injection hook).
#
# Per-role assertions:
#   - File contains the string `commands/_<role>-startup.md` (≥1 match).
#   - File does NOT contain the legacy `claude-wow-startup` sentinel
#     literal (regression guard against accidental restore of the
#     line-1 sentinel that the hook used to pattern-match against).
#   - File's first non-blank line is NOT the legacy sentinel comment
#     (explicit line-1 guard).

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
COMMANDS_DIR="$ROOT/commands"

ROLES="manager senior-developer pair-programmer tester slacker"

for role in $ROLES; do
  f="$COMMANDS_DIR/$role.md"

  # Case A: role-command file exists.
  if [ ! -f "$f" ]; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$role-file-missing ($f)")
    continue
  fi
  PASS=$((PASS+1))

  # Case B: file contains the startup-file reference.
  ref_count=$(grep -c "commands/_$role-startup\.md" "$f" || true)
  if [ "$ref_count" = "0" ]; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$role-no-startup-reference (expected ≥1 match of 'commands/_$role-startup.md')")
  else
    PASS=$((PASS+1))
  fi

  # Case C: file does NOT contain the legacy sentinel literal anywhere.
  sentinel_count=$(grep -c 'claude-wow-startup' "$f" || true)
  assert_eq "$role-no-legacy-sentinel-literal" "0" "$sentinel_count"

  # Case D: file's first non-blank line is NOT the legacy sentinel comment.
  first_nonblank=$(grep -m1 -v '^$' "$f" || true)
  case "$first_nonblank" in
    *claude-wow-startup*)
      FAIL=$((FAIL+1))
      FAILED_CASES+=("$role-line1-still-sentinel ('$first_nonblank')")
      ;;
    *)
      PASS=$((PASS+1))
      ;;
  esac
done

echo "role-files-reference-startup: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
