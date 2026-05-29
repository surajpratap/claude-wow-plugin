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
- `scripts/wow-process/` — wrapped long-running processes (`bus-tail.sh`, `github-bridge.sh`) with PID-uniqueness preambles.
- `scripts/hooks/` — registered hooks: PreToolUse (forbid direct bus writes, AskUserQuestion identity check), PostCompact (post-compaction restore), state + activity-log hooks.
- `scripts/*.sh` (top level) — plugin-runtime helper scripts role doctrine invokes via `wow-locate`: `whats-my-role.sh` (role-marker claim/release), `wow-storage.sh` (cred storage), `wow-bus-restore.sh`, `check-plugin-updates.sh`, `file-story-from-backlog.sh`, `m-prior-merge-detect.sh`, `m-activity-summary.sh`, `slack-events-trim.sh` (Slack events-feed 1-week trim), and the sprint helpers (`sprint-manifest-validate.sh`, `sprint-graph-next-dispatchable.sh`, `sprint-rebase-cascade.sh`, `sprint-merge-bump.sh`).
- `mcp/claude-wow-server/server.py` — MCP server (`bus_emit` tool; also exposes a CLI mode for hooks).
- `bridge/github/run.py` — GitHub PR bridge (Python stdlib, polls `gh api`).
- `bridge/slack/` — Slack bridge (Node, auto-launched by Slacker when configured).
- `.claude-plugin/{plugin,marketplace}.json` — manifests.

## Runtime requirements

- `bash`, `jq` 1.6+, `grep`, `sed` — for the wrapped wow-process scripts and bundled tests.
- `python3` (stdlib only; no `pip install`) — for `bridge/github/run.py` and `mcp/claude-wow-server/server.py`. Already present on every dev machine.
- `gh` CLI (authenticated) — only needed if you use the GitHub bridge. The bridge inherits ambient `gh` auth; no new credentials. Missing/unauthenticated `gh` emits `bridge-status: degraded` and the bridge keeps trying.
- `node` 20+ — only needed if you use the Slack bridge (auto-launched on `/slacker`).

## Runtime guarantees (fork-bomb resistance, Bug 0002)

The plugin's long-running scripts are **fork-bomb-resistant by construction**, regardless of how consumers drive them (subagent spawn, PATH shadowing, env shadowing, supervisor scripts, parallel tool calls). Layered defense:

- **Per-wrapper self-throttle** — every long-running script under `scripts/wow-process/` records each child-spawn timestamp to an in-process ring buffer (`spawn-rate-limit.sh`). On ≥5 spawns in a 2s window, the wrapper logs `EXIT_SPAWN_RATE` to stderr and exits non-zero. Tunable via `WOW_RUNTIME_SPAWN_WINDOW_S` + `WOW_RUNTIME_SPAWN_MAX`.
- **`wow-locate` recursion guard** — `bin/wow-locate` detects PATH-shadow (its own inode appears at a later PATH entry) and refuses with exit 3. Catches the common test-stub-delegates-to-bare-`wow-locate` recursion class.
- **Test convention lint** — `plugin/tests/no-recursive-wow-locate-stub.sh` greps every `plugin/tests/*.sh` for stub-creation patterns and fails on any `wow-locate "$@"` (or `exec wow-locate`) without a matching `REAL_WOW_LOCATE=$(command -v wow-locate)` capture earlier in the same file. Catches the class at PR time, before CI runs.

Result: a misbehaving consumer environment degrades to "a Monitor died" (CC's `Monitor` surfaces the death), not "every CC session on the host died." Consumers do not need to worry about subagent-related or PATH-shadow runtime hazards.

`claude-wow` declares six hard plugin dependencies in `.claude-plugin/plugin.json`, all from the `claude-plugins-official` marketplace; Claude Code auto-installs them transitively when `claude-wow` is installed (no manual install step). Two are used by the workflow itself — `superpowers` (M's brainstorming, SD's executing-plans/TDD, PP's receiving-code-review) and `playwright` (it bundles the Microsoft Playwright MCP server T uses for browser-driven tests — no separate `@playwright/mcp` registration). The other four — `code-review`, `security-guidance`, `claude-md-management`, `frontend-design` — are a recommended dev toolkit bundled for every consumer; no claude-wow role invokes them, so they are companions, not workflow-critical. The only consumer prerequisite is having the `claude-plugins-official` marketplace registered (Anthropic's official marketplace — near-universal).

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
