# claude-wow

A five-role multi-agent WOW for Claude Code: **Manager**, **Senior Developer**, **Pair Programmer**, **Tester**, **Slacker**. Roles coordinate through a shared append-only JSONL bus, review each other's work, and ship code together under human supervision.

## Install

```
/plugin marketplace add nedati-technologies/claude-wow-plugin@dist
/plugin install claude-wow
```

If the short URL form fails to resolve, use the long form:

```
/plugin marketplace add git+ssh://git@github.com/nedati-technologies/claude-wow-plugin.git@dist
```

## Use

Open five Claude Code sessions in the same project. In each, invoke a role:

- `/claude-wow:manager` — orchestrator, the only role that talks to the human
- `/claude-wow:senior-developer` — writes plans and ships code
- `/claude-wow:pair-programmer` — reviews plans, implementations, and bug fixes
- `/claude-wow:tester` — tests SD's finished work, files bugs
- `/claude-wow:slacker` (optional) — Slack bridge for offline updates; needs the [`claude-slack-bridge`](https://github.com/nedati-technologies/claude-slack-bridge) runner

Start **Manager first**. It sets up the `implementations/` directory layout, runs schema migrations, then prompts you to launch the peer roles in separate terminals.

## Updates

```
/plugin update claude-wow
```

Plugins do not auto-update; run this per-project whenever you want the latest WOW.

## Project-specific extensions

The role prompts are intentionally project-agnostic. **Project-specific facts go in `AGENTS.md` (or `CLAUDE.md`) at your project root** — app names, ports, credentials, framework, tooling (linters, build commands), custom rules. Agents read your project's `AGENTS.md` at startup and incorporate the contents.

## Runtime requirements

`bash`, `jq` 1.6+, `grep`, `sed`, `python3` (stdlib only). Optional: `gh` CLI (only if you use the GitHub bridge), `node` 20+ (only if you use the Slack bridge, or for T's browser-driven tests — the Playwright MCP server launches via `npx`). All standard dev-machine tools; no `pip install` or `npm install` required at the consumer.

`claude-wow` declares six hard plugin dependencies (`superpowers`, `playwright`, `code-review`, `security-guidance`, `claude-md-management`, `frontend-design`), all from the `claude-plugins-official` marketplace, which Claude Code auto-installs with the plugin. No manual install step; the only prerequisite is having `claude-plugins-official` registered (Anthropic's official marketplace).

**Dependency version policy:** dependencies intentionally track **latest** — none carry a `version` pin in `plugin.json`. The breaking-change risk is accepted and mitigated by a routine drift check: run `bash scripts/check-plugin-updates.sh --deps` (offline; lists each dependency and fails if any pin sneaks in) and `claude plugin list` to review currently-resolved versions on a cadence.

## Where to learn more

- Source repo: <https://github.com/nedati-technologies/claude-wow-plugin>
- Multi-agent protocol spec: `commands/_agent-protocol.md` (bundled)
- Migration history: `docs/superpowers/migrations/manager-schema-migrations.md` (frozen historical table, through v3.21.0) + `docs/superpowers/migrations/entries/<version>.md` (per-version files, v3.22.0+)
- Design specs + per-role learnings: in the source repo on `main`
