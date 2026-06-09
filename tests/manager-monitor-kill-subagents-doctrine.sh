#!/usr/bin/env bash
# Story 186 — the kill_subagents pause contract is documented coherently across
# roles. TaskStop is a harness tool, so this is a doctrine-SHAPE test (asserts
# the contract prose + the bus-tail-exempt lifeline carve-out), not execution.
#
# Contract:
#   - _agent-protocol.md's bounded-directive rule defines the optional
#     `kill_subagents` pause field: on kill_subagents:true, a peer TaskStops the
#     subagents/work-Monitors it spawned (tracking their task IDs) before halting.
#   - It EXEMPTS the peer's own bus-tail (the resume lifeline — never killed).
#   - Each of the 4 peer role files references the kill_subagents clause.
#   - manager.md produces the urgent pause (kill_subagents:true) on a usage-limit.
#
# RED-WITHOUT: patch .red-without/186-kill-subagents-clause.patch -> a-protocol-defines-kill-subagents
# RED-WITHOUT: patch .red-without/186-bustail-exempt.patch -> b-protocol-exempts-bustail

set -u

PASS=0
FAIL=0
FAILED_CASES=()
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}
has() { grep -q "$2" "$1" 2>/dev/null && echo yes || echo no; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
C="$ROOT/commands"
PROTO="$C/_agent-protocol.md"

# (a) protocol defines the kill_subagents field + the TaskStop-tracked-IDs contract.
# Anchor on the bullet header phrase (unique to the peer kill_subagents clause).
assert_eq "a-protocol-defines-kill-subagents" "yes" "$(has "$PROTO" 'optional pause field')"
assert_eq "a-protocol-taskstop"               "yes" "$(has "$PROTO" 'TaskStop')"
assert_eq "a-protocol-tracks-ids"             "yes" "$(has "$PROTO" 'in-session list of the task IDs')"

# (b) protocol EXEMPTS the peer's own bus-tail (the resume lifeline).
assert_eq "b-protocol-exempts-bustail" "yes" "$(has "$PROTO" 'resume lifeline')"

# (c) each of the 4 peer role files references kill_subagents + the bus-tail carve-out.
for f in senior-developer pair-programmer tester slacker; do
  assert_eq "c-$f-kill-subagents" "yes" "$(has "$C/$f.md" 'kill_subagents')"
  assert_eq "c-$f-bustail-exempt" "yes" "$(has "$C/$f.md" 'never your own bus-tail')"
done

# (d) manager.md produces the urgent pause (kill_subagents:true) on a usage-limit.
assert_eq "d-manager-kill-subagents" "yes" "$(has "$C/manager.md" 'kill_subagents')"
assert_eq "d-manager-urgent"         "yes" "$(has "$C/manager.md" 'priority.*urgent\|urgent')"

echo "manager-monitor-kill-subagents-doctrine: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
