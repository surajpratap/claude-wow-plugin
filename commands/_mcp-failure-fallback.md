# MCP failure fallback (canonical doctrine)

Project-agnostic. M-only writes (standing-authority workflow-artifact commits).

This doctrine fires when the MCP `bus_emit` tool itself fails (server crashed, validation false-positive, network down between agent and MCP). The PreToolUse hook (`scripts/hooks/wow-forbid-direct-bus-write.sh`) blocks the `>>` shortcut at the tool layer, so direct writes are not an option even when MCP is unhealthy.

## When this fires

You attempted `mcp__claude-wow__bus_emit` and got an error: connection refused, server not responding, JSON-RPC error, validation rejection that you believe is a false-positive. The bus is unreachable.

## What NOT to do

- **Do NOT** `>>` the bus file directly — the PreToolUse hook blocks this anyway, and even if it didn't, you'd skip the MCP server's validation + atomicity guarantees.
- **Do NOT** silently drop the message — peers depend on the event.
- **Do NOT** route through M via shell call or `gh` comment — M may be on the same broken MCP, and shell relay isn't a designed path.
- **Do NOT** call `AskUserQuestion` from a non-M role — the Story 048 PreToolUse hook (`scripts/hooks/check-askuserquestion-role.sh`) hard-blocks it for SD/PP/T/S regardless of MCP state. That path doesn't exist for peers.

## Canonical escalation: plain-text output to the human

The human is reading your response in the Claude UI. Output a clear plain-text message explaining the failure and what they should do. No tool needed; the message is visible immediately.

Shape:

```
⚠️ MCP bus_emit failed — bus is unreachable.

Tried to emit: type=<msg-type>, to=<addressee>, payload summary=<1-line>.

MCP error (verbatim): <paste error.message field>

To recover, please restart the MCP server:
  - In Claude Code: /mcp restart (or close and reopen the session)
  - The hook may also need /reload-plugins if the failure persists.

I'll pause here. Once you confirm MCP is back, I'll retry the emit.
```

Then wait for the human's next message. Do NOT proceed with downstream work that depends on the unsent event — the agent state has visibility into this; the rest of the system does not.

## Recovery

Once the human confirms MCP is back (via next prompt), retry the original `mcp__claude-wow__bus_emit` once. If it succeeds, proceed. If it still fails, output a fresh plain-text update and wait again — do not loop indefinitely on retries.

## Why not AskUserQuestion?

The PreToolUse hook (`scripts/hooks/check-askuserquestion-role.sh`) hard-blocks `AskUserQuestion` for SD/PP/T/S — the mechanical enforcement of "non-M agents never talk to the human directly"; bypassing it would introduce bypass-vector risk. And the bus being down doesn't change the role-routing model: the human is already watching responses in the UI, so plain-text output reaches them at the same latency `AskUserQuestion` would, while costing nothing and fighting no guardrail.
