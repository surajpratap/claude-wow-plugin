---
description: Mark human as returned from AFK; review M's autonomous decisions during the away window
---

The user typed `/back`. M's handler:

1. **Read tracker.** If `afk_active == false`, no-op: acknowledge inline ("Not AFK; nothing to do") and return. Tracker stays clean.

2. **Close the audit-log mirror file.** Append to `${ROOT}/implementations/.afk/<last_afk_session_id>-decisions.md`:
   ```
   <!-- /afk-session @ <now ISO> by <agent-id> -->
   <!-- decisions: <count of leader_decisions> -->
   ```

3. **Compute window stats.**
   - `duration_seconds = now - afk_started_ts` (parse ISO).
   - `decisions_count = len(leader_decisions)`.
   - `previous_mode = afk_mode` (will be cleared in step 5).

4. **Emit `human-back` to `*`** with payload `{previous_mode, duration_seconds, decisions_count}`.

5. **Update tracker:** `afk_active = false`, `afk_mode = null`, `afk_started_ts = null`. Keep `last_afk_session_id` (archival, not cleared). Keep `leader_decisions` array (it'll be reset on next `/afk`).

6. **Re-arm cron if was idle-mode.** When `previous_mode == "idle"`:
   - `CronCreate(cron="*/5 * * * *", prompt="<<autonomous-loop>>")`.
   - Set tracker `cron_id = <returned id>`, `quiet_ticks = 0`, `cron_cadence = "fast"`.
   When `previous_mode == "leader"`, cron is already armed; no change.

7. **Present the audit-log digest inline via `AskUserQuestion`.** Skip if `decisions_count == 0` (just ack "Welcome back; no decisions made while you were away.") and return.

   Otherwise:
   - Header: "Decisions while you were AFK"
   - Body (multi-line): list each decision with timestamp + one-liner. Reference the full audit log at `implementations/.afk/<session-id>-decisions.md`.
   - Options:
     - `Ratify all (Recommended)` — accept every decision; no further action.
     - `Drill into specific decision` — opens a sub-flow where M lets the human pick which decision to discuss.
     - `Roll back any/all` — opens a sub-flow where M reverses a chosen decision (filing backlog if needed).
     - `View full audit log` — M prints the audit-log file contents inline.

8. **Acknowledge return.** After the digest is resolved (any option), inline ack: "Welcome back. <decisions_count> decisions <ratified|drilled-into|rolled-back|reviewed>. Cron <re-armed (idle-mode)|continues (leader-mode)>."

**Idempotent:** invoking `/back` while not AFK is the same as the implicit-return path (per Section G of `commands/manager.md` AFK handling) — no-op.
