# claude-wow plugin (consumer-facing copy)

> This is the **consumer-facing** copy of AGENTS.md, bundled into the dist branch and shipped to projects that install `claude-wow` via marketplace. The **source-repo** copy at the parent repository root contains additional contributor-facing dev rules (commit hooks, mechanical-over-prose discipline, etc.). For development on the plugin itself, read both files.

The `claude-wow` Claude Code plugin: a five-role WOW (Manager, Senior Developer, Pair Programmer, Tester, Slacker). The "production code" is the markdown role prompts in `commands/`, the wow-process wrapper scripts in `scripts/wow-process/` (bus-tail, fswatch-peer, github-bridge — each with PID-uniqueness preamble), the registered hooks in `scripts/hooks/` (PreToolUse + PostCompact + state + activity-log), and the plugin manifests in `.claude-plugin/`.

## Runtime requirements

- `bash`, `jq` 1.6+, `grep`, `sed` — for the `tests/` suite and the `scripts/wow-process/` wrappers (bus-tail, fswatch-peer, github-bridge).
- **`python3`** (stdlib only — no `pip install`) — for `bridge/github/run.py`, the GitHub PR bridge, and `mcp/claude-wow-server/server.py`, the bundled MCP server. Already present on every dev machine; documented because M's Phase 3 startup spawns `python3 <plugin-cache>/bridge/github/run.py` when `${ROOT}/implementations/.github/config.json` is present, and Claude's MCP runtime spawns `python3 <plugin-cache>/mcp/claude-wow-server/server.py`.
- `gh` CLI (authenticated) — needed for the GitHub bridge to call `gh api ...`. Bridge inherits ambient `gh` auth; no new credential setup. If `gh` is missing or unauthenticated the bridge emits `bridge-status: degraded` and keeps trying.

## Testing (plugin-deliverable suite)

Programmatic checks live under `tests/` and run via plain `bash`. Run the suite as a smoke test before any commit that touches `scripts/`, `commands/`, or `.claude-plugin/`:

```bash
bash tests/run-all.sh
```

Individual tests are also runnable on their own:

| Script                                | What it covers                                                                  |
|---------------------------------------|---------------------------------------------------------------------------------|
| `tests/bus-tail-predicate.sh`         | Six-case predicate suite for `scripts/wow-process/bus-tail.sh` (forward / drop semantics).  |
| `tests/bus-tail-cursor.sh`            | `scripts/wow-process/bus-tail.sh` cursor lifecycle — first-arm-at-EOF, inode-swap clamp, cursor persistence across re-arm. |
| `tests/m-trim-threshold.sh`           | M's opportunistic trim — no-op below threshold, drops aged above.               |
| `tests/version-coherence.sh`          | `commands/manager.md`'s "Plugin version" literal matches `plugin.json`'s `version`. |
| `tests/plugin-json-schema.sh`         | `.claude-plugin/plugin.json` and `marketplace.json` parse as JSON and have the required top-level fields. |
| `tests/command-cross-refs.sh`         | Markdown link / inline-backtick paths in `commands/*.md` that look like committed repo files actually exist. |
| `tests/github-bridge-stdout-shape.sh` | `bridge/github/run.py` emits well-formed JSONL with the expected envelope (ts/from/to/type/payload). |
| `tests/github-bridge-cursor.sh`       | `bridge/github/run.py` cursor lifecycle. |
| `tests/github-bridge-pr-review.sh`    | `bridge/github/run.py` `pr-review` event lifecycle. |
| `tests/github-bridge-pr-comment.sh`   | `bridge/github/run.py` `pr-comment` event lifecycle. |
| `tests/github-bridge-ci-check.sh`     | `bridge/github/run.py` `ci-check` per-suite state tracking. |
| `tests/github-bridge-multi-repo.sh`   | `bridge/github/run.py` multi-repo handling — independent per-repo cursors. |
| `tests/github-bridge-webhook-mode.sh` | `bridge/github/run.py` webhook mode — degrades to polling when extension missing. |

Prerequisites: `bash`, `jq` 1.6+, `grep`, `sed`, `python3` (stdlib only), and `curl` (for the webhook test) — all standard dev-machine tools. The seven GitHub-bridge tests use a `gh` shim on `PATH` so they don't need a real `gh` CLI.

A non-zero exit from any single test fails the suite. `tests/command-cross-refs.sh` uses a heuristic that distinguishes `ERROR` (real broken reference) from `WARN` (heuristic-flagged path-shaped string that isn't a checkable repo reference); only ERROR lines fail the test.

## Plugin distribution

Consumers install via marketplace at `nedati-technologies/claude-wow-plugin@dist`. The `dist` branch is built from this `plugin/` subfolder via `git subtree split --prefix=plugin` and force-pushed at each release. Tags on the source repo's `main` are the release boundary; nothing is "live" until a tag goes out and downstream projects run `claude plugin update`.

Long-form marketplace URL fallback (if the short form fails): `git+ssh://git@github.com/nedati-technologies/claude-wow-plugin.git@dist`.
