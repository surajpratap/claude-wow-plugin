# Startup — shared procedures

Steps every role's `_<role>-startup.md` references. Substitute `<role>` with your
role (`manager` | `senior-developer` | `pair-programmer` | `tester` | `slacker`),
`<ROOT>` with the repo root, and `<AGENT_ID>` with the agent ID you generated.

## Resolving plugin files

Plugin files (`commands/…`, `scripts/…`, `docs/…`) live in the installed plugin, not
your project. Resolve any of them with `wow-locate`, a helper Claude Code puts on your
PATH:

```bash
AGENT_PROTOCOL=$(wow-locate commands/_agent-protocol.md)
```

`wow-locate` prints the absolute path — project-local `.claude/<path>` override first,
then the plugin install — and exits non-zero if the file is absent. `Read` the printed
path.

**Fallback** if `wow-locate` is not on PATH (older Claude Code):

```bash
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENT_PROTOCOL=$(
  ls .claude/commands/_agent-protocol.md 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/commands/_agent-protocol.md 2>/dev/null | head -1
)
```

## Arming the bus-tail Monitor

Arm ONE `Monitor` on the bus (the `Monitor` tool — NOT Bash `run_in_background`;
Monitor streams each line as an event). `persistent: true`, `timeout_ms: 3600000`,
description `"<role> bus tail on <repo-name>"`:

```bash
ROOT="<ROOT>"
BUS="$ROOT/implementations/.message-bus.jsonl"
[ -f "$BUS" ] || touch "$BUS"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BUS_TAIL=$(
  wow-locate scripts/wow-process/bus-tail.sh 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/bus-tail.sh 2>/dev/null | head -1
)
PIPE=$(
  wow-locate scripts/wow-process/monitor-pipe.sh 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/monitor-pipe.sh 2>/dev/null | head -1
)
if [ -n "$BUS_TAIL" ] && [ -n "$PIPE" ]; then
  bash "$BUS_TAIL" "$BUS" "<AGENT_ID>" "<role>" | bash "$PIPE" --purpose bus-tail
elif [ -n "$BUS_TAIL" ]; then
  exec bash "$BUS_TAIL" "$BUS" "<AGENT_ID>" "<role>"
else
  echo "[bus-tail-armed-raw] $BUS (filter script not found; raw-tail fallback)"
  exec tail -F -n 0 "$BUS"
fi
```

The filter script drops lines not addressed to you — only `*`, `<role>-*`, or your
exact agent ID fire a Monitor event. The downstream `monitor-pipe.sh`
persists the full event line to `${ROOT}/implementations/.monitor-events/bus-tail/<task-id>.jsonl`
and emits a short pointer (≤500 chars) on stdout naming the file + line + the
MCP tool (`monitor_event_read`) to load the full event. If either script is
missing, the raw-`tail` fallback works (noisier; you filter in-session and lose
the untruncation safety net for this Monitor).
