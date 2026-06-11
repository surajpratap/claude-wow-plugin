---
description: Activate AHOD mode — every agent including M owns one work item end-to-end in parallel; M coordinates, relays questions, and mirrors state
---

The user typed `/ahod`. M's handler:

1. **Role check.** Run `bash "$(wow-locate scripts/whats-my-role.sh)" whats-my-role`. If the output is not `manager`, reply "AHOD activation runs in M's terminal — re-run /ahod there" and stop.
2. **Sprint exclusivity.** If any `${ROOT}/implementations/sprints/*/manifest.json` has `"status": "active"`, refuse: "Sprint <id> is active. AHOD and sprint mode are mutually exclusive — finish or abort the sprint first." Stop.
3. **Idempotency.** `bash "$(wow-locate scripts/wow-config.sh)" get .mode` — if already `ahod`, acknowledge ("AHOD already active since <.ahod.activated_ts>") and offer a pool refresh (mini-kickoff) instead of re-activation. Stop.
4. **Confirm.** `AskUserQuestion`: "Start AHOD kickoff?" with options: pool from accepted backlog / pool from a list you give me / cancel.
5. **Flip state.**

   ```bash
   bash "$(wow-locate scripts/wow-config.sh)" set .mode '"ahod"'
   bash "$(wow-locate scripts/wow-config.sh)" set .ahod.activated_ts "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
   ```

6. **Kickoff.** Follow the Kickoff section of `commands/_ahod-doctrine.md` and the AHOD section of `commands/manager.md`: pool → foundation brainstorm → stubs in one commit → worktrees → assignments → `ahod-kickoff` broadcast → per-owner `story-created` (`ahod: true`, exact agent IDs) → collect `ahod-ack`.
7. **Acknowledge** to the human with the assignments table and the remaining pool order.

Invoking `/ahod` while AHOD is already active never re-broadcasts a kickoff (step 3 short-circuits).
