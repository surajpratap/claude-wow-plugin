# senior-developer startup procedure

The mechanical setup is scripted. Run:

```bash
bash "$(wow-locate scripts/startup.sh)" --role senior-developer
```

Consume the JSONL action stream from stdout. Each line is one of:

- `info` — print to user.
- `arm-monitor` — call the `Monitor` tool with the `spec`. Then `bash "$(wow-locate scripts/wow-process/monitor-rearm-record.sh)" <purpose> <returned-task-id>` to persist the task ID.
- `ask-human` — call `AskUserQuestion` with `{question, header, options}`. Persist the answer; then re-invoke `bash "$(wow-locate scripts/startup.sh)" --resume --answer <checkpoint_key>=<value>`.
- `complete` — startup phases done. Run `bash "$(wow-locate scripts/startup.sh)" --verify` to assert every expected Monitor's PID is alive; on non-zero exit, re-arm the missing one from the `EXIT_MISSING_MONITOR` stderr line and re-verify.
- `abort` — print the `ascii_block`, stop the turn.

The action enum is closed: `{info, arm-monitor, ask-human, complete, abort}`. There is no `schedule-wakeup` or `start-loop` value — bus consumption is always reactive Monitor, never a scheduler.

Once `complete` + `--verify` exit 0, return to `commands/senior-developer.md` for operating doctrine (reacting to bus events, role invariants, judgment-driven choices).

If the action stream printed `env: mode=ahod`, also read `commands/_ahod-doctrine.md` plus your assignment at `implementations/config.json` (`.ahod.assignments.<your-role>`) before resuming work.
