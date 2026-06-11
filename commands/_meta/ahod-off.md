---
description: Deactivate AHOD mode — wind down in-flight items (finish-to-PR or park), restore the default relay
---

The user typed `/ahod-off`. M's handler:

1. **Role check.** Run `bash "$(wow-locate scripts/whats-my-role.sh)" whats-my-role`. If the output is not `manager`, reply "AHOD stand-down runs in M's terminal — re-run /ahod-off there" and stop.
2. **Idempotency.** `bash "$(wow-locate scripts/wow-config.sh)" get .mode` — if not `ahod`, reply "AHOD is not active — nothing to do" and stop.
3. **Wind-down decisions.** Read `.ahod.assignments`. For each item whose story is not at a terminal status, ask the human: finish-to-PR or park. Use one `AskUserQuestion` with one question per item (batch up to 4 per call).
4. **Execute.** `nudge` each owner with its decision: finish-to-PR → the owner completes the owner lifecycle from wherever it is; park → the owner commits WIP to the feat branch, adds a `## Handoff` note to the story file, emits a final `status`.
5. **Flip state.**

   ```bash
   bash "$(wow-locate scripts/wow-config.sh)" set .mode '"default"'
   bash "$(wow-locate scripts/wow-config.sh)" del .ahod
   ```

6. **Broadcast** `ahod-stand-down` to `*` with payload `{reason, wind_down}` summarizing the per-item decisions.
7. **Acknowledge** to the human with the wind-down table. Parked items re-enter the default pipeline later via an ordinary `story-created` to `senior-developer-*`.

The flip happens before finish-to-PR items complete; that is intended — those items finish their solo lifecycle under default mode, and any `code-review-request` that then routes to PP is an extra safety pass.
