# claude-wow

A five-role multi-agent Way-of-Working for Claude Code:

- **Manager (M)** — orchestrates; the only role that talks to the human.
- **Senior Developer (SD)** — writes plans and ships code.
- **Pair Programmer (PP)** — reviews plans, implementations, and bug fixes.
- **Tester (T)** — tests SD's finished work and files bugs.
- **Slacker (S)** — optional; Slack-integrated agent. The Slack bridge is bundled in the plugin (`bridge/slack/`) and auto-launched by Slacker on startup (no separate process; needs `node` + Slack creds).

Roles coordinate through a shared append-only JSONL message bus at `implementations/.message-bus.jsonl` in the consuming project. Peers address each other directly via the `to` field (exact agent ID, role-glob like `senior-developer-*`, or `*` for broadcast); M doesn't route messages.

## Production code

- `commands/*.md` — role prompts + doctrine files (`_token-discipline.md`, `_retro-doctrine.md`, `_ahod-doctrine.md`, `_mcp-failure-fallback.md`, `_agent-protocol.md`).
- `scripts/wow-process/` — wrapped long-running processes (`bus-tail.sh`, `github-bridge.sh`) with PID-uniqueness preambles.
- `scripts/hooks/` — registered hooks: PreToolUse (forbid direct bus writes, AskUserQuestion identity check), PostCompact (post-compaction restore), state + activity-log hooks.
- `scripts/*.sh` (top level) — plugin-runtime helper scripts role doctrine invokes via `wow-locate`: `whats-my-role.sh` (role-marker claim/release), `wow-storage.sh` (cred storage), `wow-config.sh` (mode state in `implementations/config.json`), `wow-bus-restore.sh`, `check-plugin-updates.sh`, `file-story-from-backlog.sh`, `m-prior-merge-detect.sh`, `m-activity-summary.sh`, `slack-events-trim.sh` (Slack events-feed 1-week trim), and the sprint helpers (`sprint-manifest-validate.sh`, `sprint-graph-next-dispatchable.sh`, `sprint-rebase-cascade.sh`, `sprint-merge-bump.sh`).
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

- **Per-wrapper self-throttle (Layer A)** — every long-running script under `scripts/wow-process/` records each child-spawn timestamp to an in-process ring buffer (`spawn-rate-limit.sh`). On ≥5 spawns in a 2s window, the wrapper logs `EXIT_SPAWN_RATE` to stderr and exits non-zero. Tunable via `WOW_RUNTIME_SPAWN_WINDOW_S` + `WOW_RUNTIME_SPAWN_MAX`.
- **`wow-locate` recursion guard (Layer C)** — `bin/wow-locate` detects PATH-shadow (its own inode appears at a later PATH entry) and refuses with exit 3. Catches the common test-stub-delegates-to-bare-`wow-locate` recursion class.
- **Test convention lint (Layer D)** — `plugin/tests/no-recursive-wow-locate-stub.sh` greps every `plugin/tests/*.sh` for stub-creation patterns and fails on any `wow-locate "$@"` (or `exec wow-locate`) without a matching `REAL_WOW_LOCATE=$(command -v wow-locate)` capture earlier in the same file. Catches the class at PR time, before CI runs.
- **PreToolUse `rm`+glob block for non-M (Layer E)** — `scripts/hooks/wow-block-rm-glob-non-manager.sh` delegates to the sibling `_rm-glob-detect.py` (quote-aware `shlex` tokenization, v3.39.2): it blocks only a genuine `rm`/`rmdir`/`unlink` (or `xargs rm`) in **command position** carrying a glob (`*`/`?`/`[`), so everyday commands that merely contain the word `rm` plus a glob char (`git add 'a/*'`, `grep 'rm.*x'`, `echo "rm *"`) pass. `find -delete` / `find -exec rm` are allowed — they are the recommended escape hatch, not the shell-glob `rm` stall this guard targets (`find ... | xargs rm` still blocks via the xargs path). It resolves the role via `whats-my-role.sh` (worktree-invariant since v3.39.1 — markers live in the main repo, resolved via `--git-common-dir`); M is exempt (user-facing, the human approves CC's permission prompt directly). Non-M roles get an immediate `{decision: "block"}` JSON with remediation pointers (`find -delete`, single-file `rm -f`, or M-nudge bypass for legitimate cases) instead of silently stalling on a CC permission prompt they cannot answer. See `commands/_agent-protocol.md` "Hooks" section for the full remediation pattern.
- **Test-runner host isolation (Layer F)** — `tests/run-all.sh` (root + `plugin/`) is a thin outer wrapper that applies a per-user `ulimit -u "$WOW_TEST_PROC_BUDGET"` (default 2000; skipped when the user already has more than `budget − 500` procs to avoid breaking legitimate forks), then exec's `plugin/scripts/run-all-sandbox.py`. The Python wrapper calls `os.setsid()` to become its own session leader and registers a fork-based reaper that sweeps the process group with TERM→grace→KILL after the wrapper itself exits — so leaked grandchildren die without breaking exit-code propagation. Inside the sandbox, `tests/run-all-inner.sh` wraps every test in `timeout "$WOW_TEST_TIMEOUT_S" bash` (default 300s); an infinite-loop test is killed at the budget and recorded as a failure instead of blocking the suite forever. Both budgets are env-overridable. If `timeout(1)` is missing, the per-test wrapper degrades to plain `bash` (no upper bound on duration; ulimit + session-reap still in effect).

Result: a misbehaving consumer environment degrades to "a Monitor died" (CC's `Monitor` surfaces the death), not "every CC session on the host died." Consumers do not need to worry about subagent-related or PATH-shadow runtime hazards.

`claude-wow` declares six hard plugin dependencies in `.claude-plugin/plugin.json`, all from the `claude-plugins-official` marketplace; Claude Code auto-installs them transitively when `claude-wow` is installed (no manual install step). Two are used by the workflow itself — `superpowers` (M's brainstorming, SD's executing-plans/TDD, PP's receiving-code-review) and `playwright` (it bundles the Microsoft Playwright MCP server T uses for browser-driven tests — no separate `@playwright/mcp` registration). The other four — `code-review`, `security-guidance`, `claude-md-management`, `frontend-design` — are a recommended dev toolkit bundled for every consumer; no claude-wow role invokes them, so they are companions, not workflow-critical. The only consumer prerequisite is having the `claude-plugins-official` marketplace registered (Anthropic's official marketplace — near-universal).

**Dependency version policy (track latest).** These six dependencies intentionally track **latest** — none declare a `version` field in `plugin.json`, so consumers always resolve the newest published release. The breaking-change risk this carries is accepted deliberately and mitigated by a routine drift check rather than by pinning: `bash scripts/check-plugin-updates.sh --deps` lists each declared dependency and exits non-zero if a `version` pin is ever added (offline, jq-only — enforced in the suite via `plugin/tests/deps-track-latest.sh`); `claude plugin list` surfaces the currently-resolved versions for periodic human review. Do NOT add a `version` pin to a dependency without changing this policy.

## Plugin distribution

Consumers install from the public repo at <https://github.com/surajpratap/claude-wow-plugin>:

```
/plugin marketplace add surajpratap/claude-wow-plugin
/plugin install claude-wow
```

Long-form fallback URL if the short form fails to resolve:

```
/plugin marketplace add git+https://github.com/surajpratap/claude-wow-plugin.git
```

The public repo's `main` (and the private source repo's `dist` branch — the same tree) is built from the source repo's `plugin/` subfolder by the release script: `git subtree split --prefix=plugin` plus a source-only strip. Tags and GitHub releases are cut on the source repo; nothing is "live" for consumers until a release is cut and they run `claude plugin update`.
