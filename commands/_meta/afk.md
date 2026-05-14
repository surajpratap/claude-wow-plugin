---
description: Mark human as AFK; M decides autonomously per the Leader-AFK protocol when work is in flight, or kills cron when team is idle
---

The user typed `/afk`. M's handler:

1. **State capture.** Read M's offset tracker. Determine:
   - **In-flight stories:** any story file at `<!-- status: in-progress | in-review -->` in `${ROOT}/implementations/stories/*.md`.
   - **Open bugs:** any bug file at `<!-- status: reported | verified | triaged | fixing | fixed -->` in `${ROOT}/implementations/bugs/*.md`.
   - **Pending PR-nudge cycles:** any `story-verified` from T on the bus without a subsequent `pr-created` for the same story.

2. **Idempotent: if `afk_active == true` already**, just acknowledge inline ("Already AFK in <mode> mode since <ts>; nothing to do") and return. No state change. No re-emit on the bus.

3. **Branch on state:**
   - **Nothing in flight** (none of the three above) → `idle-AFK` mode (see "AFK handling" → "Section B" in `commands/manager.md`):
     - `CronDelete(cron_id)` — tear down the periodic check-in.
     - Set tracker `cron_id = null`, `quiet_ticks = 0`.
     - Set tracker `afk_active = true`, `afk_mode = "idle"`, `afk_started_ts = <now ISO>`.
     - Generate audit-session id `<YYYYMMDDTHHmmss>-<6hex>` from `afk_started_ts`. Set tracker `last_afk_session_id` to this id.
     - Initialize `leader_decisions = []`.
     - Create the audit-log mirror file at `${ROOT}/implementations/.afk/<session-id>-decisions.md` (best-effort `mkdir -p` first; gitignored).
     - Emit `human-afk` to `*` with payload `{mode: "idle", reason: "/afk slash command", in_flight_summary: {stories: [], bugs: []}}`.
     - Acknowledge inline: "AFK acknowledged — idle mode. Cron stopped. Bus monitor stays armed; will re-arm cron on any peer write or `/back`."
   - **Something in flight** → `Leader-AFK` mode (see "AFK handling" → "Section C"):
     - Cron stays armed at `*/5`. Do NOT call CronDelete.
     - Set tracker `afk_active = true`, `afk_mode = "leader"`, `afk_started_ts = <now ISO>`, `last_afk_session_id`, `leader_decisions = []`.
     - Create the audit-log mirror file (same as idle-mode).
     - Emit `human-afk` to `*` with payload `{mode: "leader", reason: "/afk slash command", in_flight_summary: <captured-state>}`.
     - Acknowledge inline: "AFK acknowledged — Leader mode. Soft AskUserQuestion-class decisions will be made autonomously and audit-logged. Catastrophic / irreversible actions still block (see manager.md AFK handling Section D). Use `/back` to review."

4. **No further action.** M continues normal cron behavior (idle-AFK has no cron; Leader-AFK has cron; both have bus monitor armed). All AFK-mode behavior changes happen in M's existing handlers (`AskUserQuestion`-replacement when Leader-mode active, `<user-prompt-submit-hook>` triggers implicit `/back`, etc.) per `commands/manager.md` "AFK handling" section.

**Multi-AFK note:** invoking `/afk` while already AFK is a no-op (per step 2). Don't touch `afk_started_ts` or `leader_decisions`. Don't emit a fresh `human-afk` (avoids spamming peers).

**Granularity note:** `/afk` takes no arguments. Always-binary signal. Use `/back` to return.
