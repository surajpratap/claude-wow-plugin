#!/usr/bin/env bash
# Story 152 — end-to-end smoke for each role in a temp project.
# Asserts:
#   - Each role's startup.sh completes cleanly (exit 0)
#   - Tracker file is created at the expected path
#   - hello (best-effort via MCP CLI; not asserted hard since MCP shim
#     may not respond outside a live MCP context)
#   - At least one arm-monitor instruction emitted, with spec.command
#     including the story-154 contract substring 'monitor-pipe.sh
#     --purpose <purpose>' when monitor-pipe.sh resolves; if not, the
#     empty-PIPE fallback ('exec bash ... <wrap-script>') fires —
#     test accepts either path.
#   - The expected_monitors list in the complete action matches the
#     per-role parameterization matrix.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTUP="$ROOT/scripts/startup.sh"

# Per-role expected monitors per the parameterization matrix.
# (M's `github-bridge` is conditional on `.github/config.json`; the
# test project doesn't create that, so M's expectation is just
# bus-tail + idle-monitor.)
expected_monitors_for() {
  case "$1" in
    manager) echo '["bus-tail","idle-monitor"]' ;;
    *) echo '["bus-tail"]' ;;
  esac
}

for role in manager senior-developer pair-programmer tester slacker; do
  PROJ=$(mktemp -d)
  mkdir -p "$PROJ/implementations"
  echo "falcon" > "$PROJ/implementations/.my-team"

  OUT=$(WOW_ROOT="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" bash "$STARTUP" --role "$role" 2>/dev/null)
  RC=$?
  assert_eq "$role: exit 0" "0" "$RC"

  # tracker file exists
  tracker=$(ls "$PROJ/implementations/.agents/${role}-"*.json 2>/dev/null | head -1)
  if [ -n "$tracker" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$role: no tracker file created")
  fi

  # at least one arm-monitor emitted
  arm_count=$(printf '%s\n' "$OUT" | jq -r 'select(.action == "arm-monitor") | .purpose' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$arm_count" -gt 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$role: zero arm-monitor instructions emitted")
  fi

  # arm-monitor spec.command honors story-154 (monitor-pipe.sh) OR fallback (exec bash ...)
  bad_command_count=0
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    case "$cmd" in
      *monitor-pipe.sh*--purpose*|exec\ bash*) ;;
      *)
        bad_command_count=$((bad_command_count+1))
        ;;
    esac
  done < <(printf '%s\n' "$OUT" | jq -r 'select(.action == "arm-monitor") | .spec.command' 2>/dev/null)
  assert_eq "$role: arm-monitor commands honor 154-contract or fallback" "0" "$bad_command_count"

  # complete action carries the expected_monitors list
  expect=$(expected_monitors_for "$role")
  actual=$(printf '%s\n' "$OUT" | jq -c 'select(.action == "complete") | .expect_monitors' 2>/dev/null | tail -1)
  assert_eq "$role: expect_monitors=$expect" "$expect" "$actual"

  rm -rf "$PROJ"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
