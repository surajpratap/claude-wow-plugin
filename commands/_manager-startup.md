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

## Usage auto-pause opt-in (one-time)

When the tracker key `usage_autopause` is unset, ask the human once via `AskUserQuestion` whether to enable the opt-in usage auto-pause, then persist the answer in the tracker. On opt-in, install the statusline persist wrapper: `bash "$(wow-locate scripts/wow-process/statusline-usage-persist.sh)" --install` — invoke with NO settings-path argument; the script resolves the user config-dir `settings.json` (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`) itself and never writes a project `.claude` (idempotent; `--uninstall` restores the recorded original on opt-out).

### Usage auto-pause self-check

When usage auto-pause is enabled (tracker key `usage_autopause` true, or `WOW_USAGE_AUTOPAUSE` set), run the chain verify once at startup: `bash "$(wow-locate scripts/wow-process/statusline-usage-verify.sh)"`. It prints `{healthy, checks:{installed,wired,persist_ok,statusline_emits_rate_limits}, reason}` and exits 0 when the whole chain is sound. When the opt-in is off, skip this step entirely.

This step is **non-fatal and fail-open**: startup ALWAYS continues regardless of the result, and if the helper itself errors, note "couldn't verify the usage chain" and move on. On exit 0, continue silently. On a non-zero exit, parse `checks` + `reason` and surface ONE `AskUserQuestion` matching the failed check:

- `installed` or `wired` false → the statusline wrapper isn't installed/wired though the opt-in is on. Offer: Re-install (`bash "$(wow-locate scripts/wow-process/statusline-usage-persist.sh)" --install`) / Skip / Disable the opt-in.
- `persist_ok` false → the wrapper failed a persist self-test (quote `reason`). Offer: Re-install / Investigate / Disable.
- `statusline_emits_rate_limits` false → the opt-in is on but the user's statusline does not expose `rate_limits`, so auto-pause will never fire. Offer: Keep (no-op) / Disable the opt-in / "I'll fix my statusline".

A `statusline_emits_rate_limits` value of `null` means the probe couldn't classify the statusline (e.g. it was timeout-bounded); treat it as a pass, not a failure.

## Plugin version

M targets plugin version **`3.54.0`**. This literal is read by `phase_version` (via the plugin manifest) and stamped by `sprint-merge-bump.sh` at per-item merge. When the plugin is bumped, update this line and `.claude-plugin/plugin.json` together.

The mechanical version-coherence check + migration-dispatch live in `phase_version` (`plugin/scripts/startup/phase_version.sh`); migration transforms ship as separate scripts under `plugin/scripts/migrations/<from>-<target>.sh`. Frozen legacy procedure for orientation: `commands/_manager-startup-legacy.md`.
