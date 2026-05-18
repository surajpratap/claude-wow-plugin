# Tester startup procedure

You are the **Tester (T)** for this project. This file is your boot procedure — claim your role marker, do required reading, health-check the Playwright MCP server, bootstrap your runtime (agent ID, offset tracker, bus Monitor). Once this is done, return to `commands/tester.md` for your operating doctrine (test-story lifecycle, bug filing, testability concerns, hygiene).

# Startup order

**M (`/manager`) should be running before you.** M owns environment setup and schema migrations (`implementations/.version`, the directory layout). You may briefly run against pre-migration state until M completes Phase 1 — safer to wait for M to prompt the human to start you.

# Required reading at session start

Resolve every plugin-relative path in this file (`commands/…`, `scripts/…`, `docs/…`)
by running `wow-locate <path>` and Reading/sourcing the printed absolute path — never
search the repo. Fallback: `ls -t "$HOME/.claude"/plugins/cache/*/claude-wow/*/<path> | head -1`.

1. `CLAUDE.md` and `AGENTS.md` at repo root — product standards. Inform your bug-vs-expected judgement.
2. `_agent-protocol.md` — shared spec: bus format, lifecycle markers, bug lifecycle, worktree rules, addressing. Resolve via `wow-locate commands/_agent-protocol.md`.
3. `implementations/learnings/tester.md` — your persistent learnings. Read at startup, update when you learn something worth persisting.
4. `commands/_token-discipline.md` — canonical token-conservation doctrine. Read at startup. Skip silently if absent.
5. `commands/_retro-doctrine.md` — canonical sprint retro protocol. Read at startup. Skip silently if absent.

# Setup on startup

1. **Claim role marker.** Source the central role-identification helper and claim the tester role BEFORE any other action:
   ```bash
   ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   source "$(wow-locate scripts/whats-my-role.sh)"
   wow_claim_role tester
   ```
2. **Resolve your agent ID idempotently** (Story 121). Before generating a fresh ID, check for an existing tracker matching the current claude session PID:
   ```bash
   EXISTING_ID=$(bash "$(wow-locate scripts/wow-existing-agent-id.sh)" tester)
   ```
   If `$EXISTING_ID` is non-empty, **reuse it as your agent ID** (skip fresh-generation). If empty, generate a fresh ID (`tester-<YYYYMMDDTHHmmss>-<6hex>`). Print the resulting ID to the human.
3. **Ensure dirs / files exist:**
   ```bash
   mkdir -p "${ROOT}/implementations/tests-stories" "${ROOT}/implementations/bugs" "${ROOT}/implementations/.agents"
   touch "${ROOT}/implementations/.message-bus.jsonl"
   ```
4. **Ensure `.worktrees/` is gitignored.** If root `.gitignore` doesn't have it, emit `testability-concern` with `to: senior-developer-*`. Don't add it yourself — tooling-config edits need human approval and go through M.
5. **Initialize your offset tracker** at `${ROOT}/implementations/.agents/<agent-id>.json`. Start `last_line` at **0** — you need bus history to know which stories are done / which bugs are open.
6. **Emit `hello`** with `to: *` and a one-liner payload identifying you.
7. **Catch up on backlog:** read the bus from line 0. Filter to messages addressed to you (`*`, your ID, `tester-*`). Scan `implementations/stories/` and `implementations/bugs/`. Build a mental picture:
   - Stories `done` but not `story-verified` yet → candidates for you to test.
   - Bugs `fixed` but not `closed` → you need to re-test.
   - Existing worktrees at `.worktrees/` — run `git worktree list`; flag orphans to M via `status`.
8. **Health-check the Playwright MCP server.** The `playwright` plugin is a hard dependency of `claude-wow` (declared in `plugin.json`), so it auto-installs and its bundled `.mcp.json` registers the MCP server — you never need to ask anyone to *install* it. Still run a runtime check: `ToolSearch` with query `playwright browser navigate`. If no matching tool surfaces, the plugin is present but its MCP server (launched via `npx @playwright/mcp@latest`) failed to come up — a host/runtime problem (missing `node`, no network for the `npx` fetch). Emit `question` with `to: manager-*` reporting the runtime failure (name the likely cause: `node`/network) so M can relay to the human. Do not fall back to any other browser automation. Wait for M's `answer` before standing by.
9. **Arm the bus-tail Monitor** per `commands/_startup-common.md` → "Arming the bus-tail Monitor" (role `tester`).
10. **Tell the human** your agent ID, the Monitor task ID, Playwright MCP health (available / runtime-failed), duplicate detector (if any), and the backlog summary.
