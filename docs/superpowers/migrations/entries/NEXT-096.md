# `<NEXT-from>` → `<NEXT-to>`

Slack-bridge health-monitoring doctrine coherence fix — 091 FINDING-19 (Story 096,
sprint 2026-05-17-slack-bridge-hardening). **MODIFIED** `plugin/commands/slacker.md` —
`# Bridge health monitoring` no longer lists `bridge-status` (`state: degraded` /
`stopped`) as a "Health triggers" event the bridge-spawn `Monitor` surfaces.
`bridge-status` is a bus message S itself emits (the `## Spawn-fail behavior` / re-arm
paths); it escalates through M's `### bridge-status` handler, and S no longer *also*
emits a health `question` for it — removing a double-escalation (two `AskUserQuestion`s
per spawn-fail) and a `slacker.md`↔`manager.md` framing disagreement. A "Not a health
trigger — `bridge-status`" note replaces the removed bullet, and the escalation
payload's `reason` enumeration drops the now-impossible "bridge-status reason". No
behavior change beyond doctrine coherence; 091's once-per-outage cadence is preserved.
Doctrine-only — no bridge code, no new test; bundled bash test-suite count unchanged.
**Consumer action after upgrade:** `claude plugin update claude-wow`, `/reload-plugins`,
restart peers (S re-reads its role file). Just update `.version`.
