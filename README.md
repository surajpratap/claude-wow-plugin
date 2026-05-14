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

- `/claude-wow:manager` — orchestrator, only one that talks to the human
- `/claude-wow:senior-developer` — writes plans and ships code
- `/claude-wow:pair-programmer` — reviews plans, code, and bug fixes
- `/claude-wow:tester` — tests SD's finished work, files bugs
- `/claude-wow:slacker` (optional) — Slack bridge for offline updates

Start Manager first; it sets up the directory layout and schema migrations.

## Where to learn more

- Source repo: <https://github.com/nedati-technologies/claude-wow-plugin>
- Multi-agent protocol spec: `commands/_agent-protocol.md` (bundled)
- Migration history: `docs/superpowers/migrations/manager-schema-migrations.md` (bundled)
- Per-role learnings + design notes: in the source repo on `main`

## Runtime requirements

`bash` 4+, `jq` 1.6+, `grep`, `sed`, `python3` (stdlib only), `gh` CLI (authenticated, optional — only needed if you use the GitHub bridge). All standard dev-machine tools; no `pip install` or `npm install` needed at consumer side. The Slack bridge auto-installs its own `node_modules/` on first use (npm required).
