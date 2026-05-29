#!/usr/bin/env bash
# Story 152 — resume protocol. Drives the ask-human → exit → resume
# --answer → continues cycle for the checkpoint library.
#
# This story ships the checkpoint primitives; full ask-human emit from
# any phase function is deferred (version + peer phases handle their
# own ask-human triggers). This test exercises the lib_checkpoint API
# directly via a shell harness that mimics the phase contract.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT/scripts/startup/lib_checkpoint.sh"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/implementations/.agents"
export WOW_ROOT="$PROJ"
# shellcheck disable=SC1090
. "$LIB"

# Case 1: write_checkpoint creates the file with the expected shape
write_checkpoint "test-agent-id" "phase_version" "version_confirm" '{"role":"manager"}'
ckpt="$PROJ/implementations/.agents/test-agent-id.startup-state.json"
assert_eq "case1: checkpoint file exists" "yes" "$([ -f "$ckpt" ] && echo yes || echo no)"
phase_val=$(jq -r .phase "$ckpt")
assert_eq "case1: phase field correct" "phase_version" "$phase_val"
pending=$(jq -r .pending_answer_key "$ckpt")
assert_eq "case1: pending_answer_key correct" "version_confirm" "$pending"

# Case 2: mark_phase_complete appends to completed_phases (idempotent)
mark_phase_complete "test-agent-id" "phase_env"
mark_phase_complete "test-agent-id" "phase_env"
mark_phase_complete "test-agent-id" "phase_layout"
completed=$(jq -c '.completed_phases' "$ckpt")
assert_eq "case2: completed_phases dedups + grows" '["phase_env","phase_layout"]' "$completed"

# Case 3: read_checkpoint returns the JSON; non-existent returns non-zero
out=$(read_checkpoint "test-agent-id")
out_phase=$(printf '%s' "$out" | jq -r .phase)
assert_eq "case3: read_checkpoint returns phase" "phase_version" "$out_phase"
read_checkpoint "no-such-agent" >/dev/null 2>&1
assert_eq "case3: missing checkpoint non-zero exit" "1" "$?"

# Case 4: validate_answer
validate_answer "version_confirm" "version_confirm" 2>/dev/null
assert_eq "case4: matching answer key OK" "0" "$?"
validate_answer "expected_key" "got_key" 2>/dev/null
assert_eq "case4: mismatched answer key non-zero" "1" "$?"

# Case 5: remove_checkpoint cleans up
remove_checkpoint "test-agent-id"
assert_eq "case5: checkpoint removed" "no" "$([ -f "$ckpt" ] && echo yes || echo no)"

# Case 6: --resume --answer <k>=<v> drives the full re-entry path.
# Set up a checkpoint, then run startup.sh --resume.
mkdir -p "$PROJ/implementations"
echo "falcon" > "$PROJ/implementations/.my-team"
write_checkpoint "manager-resume-test" "phase_env" "team_name" '{"role":"manager"}'
RESUME_OUT=$(WOW_ROOT="$PROJ" bash "$ROOT/scripts/startup.sh" --resume --answer team_name=falcon 2>&1)
RESUME_RC=$?
# Resume should have applied the answer to env_snapshot AND re-run
# phases (so we see env / layout / etc. info lines)
if printf '%s' "$RESUME_OUT" | grep -q '"action":"info"' ; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("case6: --resume produced no info actions")
fi
# Answer key persisted into env_snapshot
updated=$(jq -r '.env_snapshot.team_name // empty' "$PROJ/implementations/.agents/manager-resume-test.startup-state.json" 2>/dev/null)
assert_eq "case6: answer key persisted into env_snapshot" "falcon" "$updated"

rm -rf "$PROJ"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
