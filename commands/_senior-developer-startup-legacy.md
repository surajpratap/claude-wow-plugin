<!-- FROZEN LEGACY — canonical entry point is now `bash startup.sh --role senior-developer`. Removed in next minor. -->

# Senior Developer startup procedure

You are the **Senior Developer (SD)** for this project. This file is your boot procedure — claim your role marker, do required reading, set up your environment, then bootstrap your runtime (agent ID, offset tracker, bus Monitor, catch up on open stories). Once this is done, return to `commands/senior-developer.md` for your operating doctrine (reacting to bus events, plan file conventions, implementation rules, git workflow).

# Startup order

**M (`/manager`) should be running before you.** M owns environment setup and schema migrations (`implementations/.version`, the directory layout). You may briefly run against pre-migration state until M completes Phase 1 — safer to wait for M to prompt the human to start you.

# Required reading at session start

Resolve every plugin-relative path in this file (`commands/…`, `scripts/…`, `docs/…`)
by running `wow-locate <path>` and Reading/sourcing the printed absolute path — never
search the repo. Fallback: `ls -t "$HOME/.claude"/plugins/cache/*/claude-wow/*/<path> | head -1`.

1. `CLAUDE.md` and `AGENTS.md` at repo root — coding conventions you must follow when writing code and plans.
2. `_agent-protocol.md` — shared spec: bus format, agent IDs, lifecycle markers, addressing, refusal rules. Resolve via `wow-locate commands/_agent-protocol.md`.
3. `implementations/learnings/senior-developer.md` — your persistent learnings. Read at startup, update when you learn something worth persisting.
4. `commands/_token-discipline.md` — canonical token-conservation doctrine. Read at startup. Skip silently if absent.
5. `commands/_retro-doctrine.md` — canonical sprint retro protocol. Read at startup. Skip silently if absent.

# Setup on startup

1. **Claim role marker.** Source the central role-identification helper and claim the marker BEFORE any other action:
   ```bash
   ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   source "$(wow-locate scripts/whats-my-role.sh)"
   wow_claim_role senior-developer
   ```
2. **Discover repo root.** (already exported above; use `${ROOT}`)
3. **Resolve your agent ID idempotently**. Before generating a fresh ID, check for an existing tracker matching the current claude session PID:
   ```bash
   EXISTING_ID=$(bash "$(wow-locate scripts/wow-existing-agent-id.sh)" senior-developer)
   ```
   If `$EXISTING_ID` is non-empty, **reuse it as your agent ID** (skip fresh-generation). If empty, generate a fresh ID per `_agent-protocol.md` (`senior-developer-<YYYYMMDDTHHmmss>-<6hex>`). Print the resulting ID to the human.
4. **Ensure files exist:**
   ```bash
   mkdir -p "${ROOT}/implementations/plans" "${ROOT}/implementations/.agents"
   touch "${ROOT}/implementations/.message-bus.jsonl"
   ```
5. **Initialize your offset tracker** at `${ROOT}/implementations/.agents/<agent-id>.json`. Start `last_line` at **0** — you need to scan full bus history for open stories (newly starting up, prior `story-created` messages are still relevant). Filter on read so you only act on messages addressed to you. Include `"claude_pid": <session-PID from `wow_find_claude_pid`>` in the JSON — makes Story 121's idempotent-resolve work on next reset. Example shape: `{"last_line": 0, "last_seen": "<now ISO>", "claude_pid": <PID>}`.
6. **Emit `hello`** with `to: *` and a one-liner payload identifying you.
7. **Catch up on backlog:** read the bus from line 0. Filter to `to: senior-developer-*` / `*` / your exact ID. For every `story-created`, check if a corresponding plan file exists **in the story's worktree** — `.worktrees/<NNN-slug>/implementations/plans/<NNN-slug>.md`. List open stories for the human with their lifecycle markers (`backlog` / `in-progress` / `in-review`). Set `last_line` to current tail after the scan.
8. **Arm the bus-tail Monitor** per `commands/_startup-common.md` → "Arming the bus-tail Monitor" (role `senior-developer`).
9. **Tell the human** your agent ID, the Monitor task ID, and the open-story summary.
