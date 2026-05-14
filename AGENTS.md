# claude-wow

A five-role multi-agent Way-of-Working for Claude Code:

- **Manager (M)** — orchestrates; the only role that talks to the human.
- **Senior Developer (SD)** — writes plans and ships code.
- **Pair Programmer (PP)** — reviews plans, implementations, and bug fixes.
- **Tester (T)** — tests SD's finished work and files bugs.
- **Slacker (S)** — optional; Slack-integrated agent for projects that use the [`claude-slack-bridge`](https://github.com/nedati-technologies/claude-slack-bridge) runner.

Roles coordinate through a shared append-only JSONL message bus at `implementations/.message-bus.jsonl` in the consuming project. Peers address each other directly via the `to` field (exact agent ID, role-glob like `senior-developer-*`, or `*` for broadcast); M doesn't route messages.

## Production code

- `commands/*.md` — role prompts + doctrine files (`_token-discipline.md`, `_retro-doctrine.md`, `_mcp-failure-fallback.md`, `_agent-protocol.md`).
- `scripts/wow-process/` — wrapped long-running processes (`bus-tail.sh`, `fswatch-peer.sh`, `github-bridge.sh`) with PID-uniqueness preambles.
- `scripts/hooks/` — registered hooks: PreToolUse (forbid direct bus writes, AskUserQuestion identity check), PostCompact (post-compaction restore), state + activity-log hooks.
- `mcp/claude-wow-server/server.py` — MCP server (`bus_emit` tool; also exposes a CLI mode for hooks).
- `bridge/github/run.py` — GitHub PR bridge (Python stdlib, polls `gh api`).
- `bridge/slack/` — Slack bridge (Node, auto-launched by Slacker when configured).
- `.claude-plugin/{plugin,marketplace}.json` — manifests.

## Runtime requirements

- `bash`, `jq` 1.6+, `grep`, `sed` — for the wrapped wow-process scripts and bundled tests.
- `python3` (stdlib only; no `pip install`) — for `bridge/github/run.py` and `mcp/claude-wow-server/server.py`. Already present on every dev machine.
- `gh` CLI (authenticated) — only needed if you use the GitHub bridge. The bridge inherits ambient `gh` auth; no new credentials. Missing/unauthenticated `gh` emits `bridge-status: degraded` and the bridge keeps trying.
- `fswatch` — used by PP and T for file-watch Monitors. macOS: `brew install fswatch`; Linux: distro package.
- `node` 20+ — only needed if you use the Slack bridge (auto-launched on `/slacker`).
- `@playwright/mcp` — only needed if T performs browser-driven tests.

## Plugin distribution

Consumers install via the marketplace at the `dist` branch:

```
/plugin marketplace add nedati-technologies/claude-wow-plugin@dist
/plugin install claude-wow
```

Long-form fallback URL if the short form fails to resolve:

```
/plugin marketplace add git+ssh://git@github.com/nedati-technologies/claude-wow-plugin.git@dist
```

The `dist` branch is built from this `plugin/` subfolder on the [source repo](https://github.com/nedati-technologies/claude-wow-plugin) via `git subtree split --prefix=plugin`. Tags on the source repo's `main` are the release boundary; nothing is "live" for consumers until a tag is cut and they run `claude plugin update`.
