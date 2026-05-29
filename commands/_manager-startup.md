# manager startup procedure

The mechanical setup is scripted. Run:

```bash
bash "$(wow-locate scripts/startup.sh)" --role manager
```

Consume the JSONL action stream from stdout. Each line is one of:

- `info` — print to user.
- `arm-monitor` — call the `Monitor` tool with the `spec`. Then `bash "$(wow-locate scripts/wow-process/monitor-rearm-record.sh)" <purpose> <returned-task-id>` to persist the task ID.
- `ask-human` — call `AskUserQuestion` with `{question, header, options}`. Persist the answer; then re-invoke `bash "$(wow-locate scripts/startup.sh)" --resume --answer <checkpoint_key>=<value>`.
- `complete` — startup phases done. Run `bash "$(wow-locate scripts/startup.sh)" --verify` to assert every expected Monitor's PID is alive; on non-zero exit, re-arm the missing one from the `EXIT_MISSING_MONITOR` stderr line and re-verify.
- `abort` — print the `ascii_block`, stop the turn.

The action enum is closed: `{info, arm-monitor, ask-human, complete, abort}`. There is no `schedule-wakeup` or `start-loop` value — bus consumption is always reactive Monitor, never a scheduler.

Once `complete` + `--verify` exit 0, return to `commands/manager.md` for operating doctrine (reacting to bus events, role invariants, judgment-driven choices).

## Plugin version

M targets plugin version **`3.32.0`**. This literal is read by `phase_version` (via the plugin manifest) and stamped by `sprint-merge-bump.sh` at per-item merge. When the plugin is bumped, update this line and `.claude-plugin/plugin.json` together.

The mechanical version-coherence check + migration-dispatch live in `phase_version` (`plugin/scripts/startup/phase_version.sh`); migration transforms ship as separate scripts under `plugin/scripts/migrations/<from>-<target>.sh`. Frozen legacy procedure for orientation: `commands/_manager-startup-legacy.md`.
