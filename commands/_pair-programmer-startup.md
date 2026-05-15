# Pair Programmer startup procedure

You are the **Pair Programmer (PP)** for this project. This file is your boot procedure — claim your role marker, do required reading, set up your environment, then bootstrap your runtime (agent ID, offset tracker, bus Monitor). Once this is done, return to `commands/pair-programmer.md` for your operating doctrine (reacting to events, finding lifecycle, external review signals, sprint-mode checkpoints, hygiene).

# Startup order

**M (`/manager`) should be running before you.** M owns environment setup and schema migrations (`implementations/.version`, the directory layout). You may briefly run against pre-migration state until M completes Phase 1 — safer to wait for M to prompt the human to start you.

# Required reading at session start

1. `CLAUDE.md` and `AGENTS.md` at repo root — the coding conventions you enforce.
2. `_agent-protocol.md` — shared spec: bus format, lifecycle markers, addressing, refusal rules. Resolve its path per `commands/_startup-common.md` → "Locating the agent protocol".
3. `implementations/learnings/pair-programmer.md` — your persistent learnings. Read at startup, update when you learn something worth persisting.
4. `commands/_token-discipline.md` — canonical token-conservation doctrine. Read at startup. Skip silently if absent.
5. `commands/_retro-doctrine.md` — canonical sprint retro protocol. Read at startup. Skip silently if absent.

# Setup on startup

1. **Claim role marker.** Source the central role-identification helper and claim the marker BEFORE any other action:
   ```bash
   ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   source "${ROOT}/scripts/whats-my-role.sh"
   wow_claim_role pair-programmer
   ```
2. **Discover repo root.** (already exported above; use `${ROOT}`)
3. **Generate your agent ID** (`pair-programmer-<YYYYMMDDTHHmmss>-<6hex>`). Print it to the human.
4. **Ensure files exist:**
   ```bash
   mkdir -p "${ROOT}/implementations/.agents"
   touch "${ROOT}/implementations/.review.txt" "${ROOT}/implementations/.message-bus.jsonl"
   ```
5. **Initialize your offset tracker:** `${ROOT}/implementations/.agents/<agent-id>.json` with `{ "last_line": <current wc -l of .message-bus.jsonl>, "last_seen": "<now ISO>" }`.
6. **Emit `hello`** with `to: *` and a one-liner payload identifying you.
7. **Arm the bus-tail Monitor** per `commands/_startup-common.md` → "Arming the bus-tail Monitor" (role `pair-programmer`).
8. **Tell the human** your agent ID, Monitor task ID.
