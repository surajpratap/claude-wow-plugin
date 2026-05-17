# `<NEXT-from>` → `<NEXT-to>`

Slacker workspace-id populate + repair, and the unified Slack-bridge fail-closed
escalation contract (Story 097, sprint 2026-05-17-slack-bridge-hardening). **MODIFIED**
`plugin/commands/slacker.md` — a new `## Workspace learning` section (the
`<!-- slacker-workspace -->` learnings block); `## Bridge auto-launch` gains step
`4d. Resolve workspace` (089-style one-time confirm — validate `^T[A-Z0-9]+$`/`skip`,
persist) and passes `BRIDGE_WORKSPACE_ID` on both spawn branches; `## Spawn-fail
behavior` is generalized to parse both fail-closed bridge stdout shapes
(`workspace mismatch:` and `missing OAuth scope(s):`) into a single cause-named
`bridge-status` (no sibling `status`); a new `## Bridge-repair signals` section handles
the `workspace-id` re-pin and `restart-bridge` repair `nudge`s, each re-running the
full post-resolve relaunch; `# Bridge health monitoring` gains a task-id-scoped
fail-closed discriminator that suppresses the story-091 health-`question` path on a
startup fail-closed exit. **MODIFIED** `plugin/commands/manager.md` — the
`### bridge-status` handler gets a concrete workspace-mismatch repair (`Re-enter the
expected workspace ID` + a `nudge` to the exact originating S agent ID) and a new
missing-OAuth-scope escalation branch; both Slack branches short-circuit the GitHub
"Tracker bookkeeping" step. **MODIFIED** `plugin/commands/_slacker-startup.md` — the
step-4 bridge-auto-launch summary names the new "Resolve workspace" sub-step.
Doctrine-only — no bridge code, no new test; bundled bash test-suite count unchanged.
**Consumer action after upgrade:** `claude plugin update claude-wow`, `/reload-plugins`,
restart peers (M + S re-read their role files). Just update `.version`.
