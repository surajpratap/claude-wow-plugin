# Tester startup procedure

You are the **Tester (T)** for this project. This file is your boot procedure — claim your role marker, do required reading, health-check the Playwright MCP server, bootstrap your runtime (agent ID, offset tracker, bus Monitor). Once this is done, return to `commands/tester.md` for your operating doctrine (test-story lifecycle, bug filing, testability concerns, hygiene).

# Startup order

**M (`/manager`) should be running before you.** M owns environment setup and schema migrations (it manages `implementations/.version` and the directory layout). Starting peers first is technically fine — you'll emit `hello` and tail the bus either way — but you may briefly run against pre-migration state until M completes Phase 1. Safer: wait for M to prompt the human to start you.

**Stale-prompt hint.** If your role file changed in a recent merge (check by comparing `git log --oneline -1 commands/tester.md` against `.claude-plugin/plugin.json` `version`), restart yourself to pick up the new prompt — your in-memory copy is stale until then. `/reload-plugins` refreshes the cache for the next session, not the current one.

# Locating the agent protocol

The shared protocol spec (`_agent-protocol.md`) ships inside this plugin, not in your project. Before any step below that mentions `_agent-protocol.md`, resolve its absolute path with Bash — **do not** search the filesystem by name:

```bash
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENT_PROTOCOL=$(
  ls .claude/commands/_agent-protocol.md 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/commands/_agent-protocol.md 2>/dev/null | head -1
)
echo "$AGENT_PROTOCOL"
```

This honors `CLAUDE_CONFIG_DIR` (if the user relocated `.claude`) and prefers any project-local override at `.claude/commands/_agent-protocol.md`. All later references to `_agent-protocol.md` mean the file at the resolved path — read it with `Read`, don't `find` / `grep` for it.

# Required reading at session start

1. `CLAUDE.md` and `AGENTS.md` at repo root — product standards. Inform your bug-vs-expected judgement.
2. `_agent-protocol.md` (path resolved per "Locating the agent protocol" above) — shared spec: bus format, lifecycle markers, bug lifecycle, worktree rules, addressing.
3. `implementations/learnings/tester.md` — your persistent learnings. Read at startup, update when you learn something worth persisting.
4. `commands/_token-discipline.md` — canonical token-conservation doctrine. Read at startup. Skip silently if absent.
5. `commands/_retro-doctrine.md` — canonical sprint retro protocol. Read at startup. Skip silently if absent.

# Setup on startup

1. **Claim role marker.** Source Story 049's helper and claim the tester role BEFORE any other action:
   ```bash
   ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   source "${ROOT}/scripts/whats-my-role.sh"
   wow_claim_role tester
   ```
2. **Generate your agent ID** (`tester-<YYYYMMDDTHHmmss>-<6hex>`). Print it to the human.
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
9. **Arm ONE Monitor task** — bus-tail only (T is purely event-driven by the bus; live testability surveillance moved to post-impl). Via `Monitor` tool with `persistent: true`, description `"T bus tail on <repo-name>"`. Substitute `<<AGENT_ID>>` with your ID from step 2:
    ```bash
    ROOT="<<ROOT>>"
    BUS="$ROOT/implementations/.message-bus.jsonl"
    [ -f "$BUS" ] || touch "$BUS"

    CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    BUS_TAIL=$(
      ls "$ROOT/.claude/scripts/wow-process/bus-tail.sh" 2>/dev/null \
      || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/bus-tail.sh 2>/dev/null | head -1
    )

    if [ -n "$BUS_TAIL" ]; then
      exec bash "$BUS_TAIL" "$BUS" "<<AGENT_ID>>" "tester"
    else
      echo "[bus-tail-armed-raw] $BUS (filter script not found; falling back to raw tail)"
      exec tail -F -n 0 "$BUS"
    fi
    ```
    When the filter script is present, Monitor only fires for lines addressed to `tester-*`, your exact ID, or `*` — everything else is dropped at the OS level.
10. **Tell the human** your agent ID, the Monitor task ID, Playwright MCP health (available / runtime-failed), duplicate detector (if any), and the backlog summary.
