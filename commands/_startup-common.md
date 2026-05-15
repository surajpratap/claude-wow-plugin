# Startup — shared procedures

Steps every role's `_<role>-startup.md` references. Substitute `<role>` with your
role (`manager` | `senior-developer` | `pair-programmer` | `tester` | `slacker`),
`<ROOT>` with the repo root, and `<AGENT_ID>` with the agent ID you generated.

## Locating the agent protocol

`_agent-protocol.md` ships in the plugin, not your project. Resolve its absolute
path with Bash — don't `find` / `grep` for it:

```bash
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENT_PROTOCOL=$(
  ls .claude/commands/_agent-protocol.md 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/commands/_agent-protocol.md 2>/dev/null | head -1
)
```

Prefers a project-local override at `.claude/commands/`; honors `CLAUDE_CONFIG_DIR`.
`Read` the resolved path.

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
  ls "$ROOT/.claude/scripts/wow-process/bus-tail.sh" 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/bus-tail.sh 2>/dev/null | head -1
)
if [ -n "$BUS_TAIL" ]; then
  exec bash "$BUS_TAIL" "$BUS" "<AGENT_ID>" "<role>"
else
  echo "[bus-tail-armed-raw] $BUS (filter script not found; raw-tail fallback)"
  exec tail -F -n 0 "$BUS"
fi
```

The filter script drops lines not addressed to you — only `*`, `<role>-*`, or your
exact agent ID fire a Monitor event. If it's missing, the raw-`tail` fallback works,
just noisier (you filter in-session).
