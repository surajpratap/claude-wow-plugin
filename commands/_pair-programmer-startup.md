# Pair Programmer startup procedure

You are the **Pair Programmer (PP)** for this project. This file is your boot procedure — claim your role marker, do required reading, set up your environment, then bootstrap your runtime (agent ID, offset tracker, bus Monitor). Once this is done, return to `commands/pair-programmer.md` for your operating doctrine (reacting to events, finding lifecycle, external review signals, sprint-mode checkpoints, hygiene).

# Startup order

**M (`/manager`) should be running before you.** M owns environment setup and schema migrations (it manages `implementations/.version` and the directory layout). Starting peers first is technically fine — you'll emit `hello` and tail the bus either way — but you may briefly run against pre-migration state until M completes Phase 1. Safer: wait for M to prompt the human to start you.

**Stale-prompt hint.** If your role file changed in a recent merge (check by comparing `git log --oneline -1 commands/pair-programmer.md` against `.claude-plugin/plugin.json` `version`), restart yourself to pick up the new prompt — your in-memory copy is stale until then. `/reload-plugins` refreshes the cache for the next session, not the current one.

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

1. `CLAUDE.md` and `AGENTS.md` at repo root — the coding conventions you enforce.
2. `_agent-protocol.md` (path resolved per "Locating the agent protocol" above) — shared spec: bus format, lifecycle markers, addressing, refusal rules.
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
7. **Arm a bus-tail Monitor task** (via the `Monitor` tool, NOT Bash background):
   - **bus tail** on `.message-bus.jsonl` through the shared filter script (see `_agent-protocol.md` → "Bus-tail filter script"). `persistent: true`, description `"PP bus tail on <repo-name>"`. Substitute `<<AGENT_ID>>` with your ID from step 3:
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
       exec bash "$BUS_TAIL" "$BUS" "<<AGENT_ID>>" "pair-programmer"
     else
       echo "[bus-tail-armed-raw] $BUS (filter script not found; falling back to raw tail)"
       exec tail -F -n 0 "$BUS"
     fi
     ```
     When the filter script is present, Monitor only fires for lines addressed to `pair-programmer-*`, your exact ID, or `*` — everything else is dropped at the OS level.
8. **Tell the human** your agent ID, Monitor task ID.
