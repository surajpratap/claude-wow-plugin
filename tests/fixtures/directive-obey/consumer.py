#!/usr/bin/env python3
"""Reference ROLE-ASYMMETRIC consumer for the bounded directive-obey rule
(Story 172, §4 + FINDING-47).

A mechanical embodiment of `_agent-protocol.md` "Bounded directive-obey rule"
as a role applies it on each bus message — the code-under-test the behavioral
`directive-obey.sh` drives and the `directive-obey-{check,escalate}.patch`
revert (revert → the role absorbs-not-acts → the test flips RED).

Reads one bus message (JSON) on argv[1], the paused-state file on argv[2], and
an optional role on argv[3] (default "peer"). Applies the rule, updates the
paused-state file, and prints the action it took:
HALTED | RESUMED | WORKED | ABSORBED | ESCALATED | AVAILABLE.

CLOSED ENUM {pause, resume, escalate}, exact string equality — never eval/exec a
directive value (the out-of-set case proves it is not an injection channel).
Role-asymmetric:

  PEER (senior-developer / pair-programmer / tester / slacker):
    - directive == "pause"  (EXACT)  → set paused; print HALTED.
    - directive == "resume" (EXACT)  → clear paused; print RESUMED.
    - directive == "escalate"        → IGNORED (M-only); absorb (ABSORBED).
    - any other directive value      → IGNORED; absorb (ABSORBED/WORKED).
  MANAGER (the driver / human-channel / resume-producer):
    - directive == "escalate" (EXACT)→ ACT: escalate to human; print ESCALATED.
    - pause / resume / anything else → EXEMPT: absorb for awareness; print
                                       AVAILABLE (never halted).
"""
import json
import os
import sys

# CLOSED enum {pause, resume, escalate} (see module docstring); peers act on
# PEER_ACT_SET only — escalate is the manager's directive (role-asymmetry).
PEER_ACT_SET = ("pause", "resume")


def load_paused(state_path):
    try:
        with open(state_path) as f:
            return json.load(f).get("paused", False)
    except (OSError, json.JSONDecodeError, ValueError):
        return False


def save_paused(state_path, paused):
    with open(state_path, "w") as f:
        json.dump({"paused": paused}, f)


def main():
    msg = json.loads(sys.argv[1])
    state_path = sys.argv[2]
    role = sys.argv[3] if len(sys.argv) > 3 else "peer"
    paused = load_paused(state_path)
    payload = msg.get("payload") or {}
    directive = payload.get("directive")

    if role == "manager":
        # MANAGER is role-asymmetric: EXEMPT from pause/resume (the driver is
        # never halted) but ACTS on escalate (the sole human channel).
        # --- MANAGER-ESCALATE-ARM-START (directive-obey-escalate.patch reverts this block) ---
        if directive == "escalate":
            print("ESCALATED")
            return 0
        # --- MANAGER-ESCALATE-ARM-END ---
        # pause / resume / anything else: absorb for awareness, stay AVAILABLE.
        print("AVAILABLE")
        return 0

    # --- PEER role (default) ---
    # --- DIRECTIVE-OBEY-CHECK-START (directive-obey-check.patch reverts this block) ---
    if directive == "pause":
        save_paused(state_path, True)
        print("HALTED")
        return 0
    if directive == "resume":
        save_paused(state_path, False)
        print("RESUMED")
        return 0
    # --- DIRECTIVE-OBEY-CHECK-END ---

    # absorb-unknown fallback (the normal peer path). When paused, a peer
    # ignores other nudges; otherwise it works. A peer IGNORES escalate (M-only)
    # and any out-of-set directive — never executed.
    if paused:
        print("STILL-HALTED")
        return 0
    if directive is not None and directive not in PEER_ACT_SET:
        # escalate (M-only) or out-of-set: IGNORED by peers — NOT executed.
        print("ABSORBED")
        return 0
    print("WORKED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
