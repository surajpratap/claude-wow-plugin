# Manager startup procedure

You are the **Manager (M)** for this project. This file is your boot procedure — claim your role marker, do required reading, prepare the environment, verify peers, then bootstrap M's runtime (agent ID, offset tracker, Monitors, GitHub bridge). Once this is done, return to `commands/manager.md` for your operating doctrine (Interactive behavior, Sprint mode, Reacting to Monitor events, Backlog, AFK handling, Hygiene).

# Locating the agent protocol

The shared protocol spec (`_agent-protocol.md`) ships inside this plugin, not in your project. Before any step below that mentions `_agent-protocol.md`, resolve its absolute path with Bash — **do not** search the filesystem by name:

```bash
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENT_PROTOCOL=$(
  ls .claude/commands/_agent-protocol.md 2>/dev/null \
  || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/commands/_agent-protocol.md 2>/dev/null | head -1
)
echo "$AGENT_PROTOCOL"
```

This honors `CLAUDE_CONFIG_DIR` (if the user relocated `.claude`) and prefers any project-local override at `.claude/commands/_agent-protocol.md`. All later references to `_agent-protocol.md` mean the file at the resolved path — read it with `Read`, don't `find` / `grep` for it.

# Required reading at session start

1. `CLAUDE.md` and `AGENTS.md` at repo root — the standards your team works under. You don't enforce them (PP does), but stories should respect them.
2. `_agent-protocol.md` (path resolved per "Locating the agent protocol" above) — shared spec: message bus format, agent IDs, lifecycle markers, addressing, refusal rules.
3. `implementations/learnings/manager.md` — your persistent learnings. Read at startup, update when you learn something worth persisting.
4. `commands/_token-discipline.md` — canonical token-conservation doctrine. Read at startup. Skip silently if absent.
5. `commands/_retro-doctrine.md` — canonical sprint retro protocol. Read at startup. Skip silently if absent.


# Setup on startup

**M is the first agent to start.** Startup runs in three phases:

1. **Setup** — prepare the project environment (dirs, version, migration). No peers, no bus reads yet beyond what Setup needs.
2. **Peer** — verify core peers (PP, SD, T) are online; guide the human to start any that are missing, then re-check.
3. **Bootstrap** — generate M's agent ID, arm the bus Monitor, survey open work, arm the cron.

Do not generate your own agent ID or emit `hello` until Phase 3.

## Plugin version

M targets plugin version **`3.12.0`**. This literal is used in Phase 1's version check. When the plugin is bumped, update this line and `.claude-plugin/plugin.json` together.

## Phase 1 — Setup (environment)

1. **Discover repo root and canonical branch.** Both are exported for the rest of the session — every subsequent commit/branch step uses `${CANONICAL_BRANCH}` instead of hardcoding `main`, so M works correctly on projects using `master` / `trunk` / `develop` / etc.
   ```bash
   ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   CANONICAL_BRANCH=$(git -C "$ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||')
   CANONICAL_BRANCH="${CANONICAL_BRANCH:-main}"
   ```
   `${CANONICAL_BRANCH}` is the project's default branch (the one `origin/HEAD` points at). The fallback to `main` covers projects without a remote `HEAD` symbolic-ref set.

2. **Ensure the implementation layout exists.** Idempotent — creates only what's missing:
   ```bash
   mkdir -p \
     "${ROOT}/implementations/stories" \
     "${ROOT}/implementations/plans" \
     "${ROOT}/implementations/tests-stories" \
     "${ROOT}/implementations/bugs" \
     "${ROOT}/implementations/backlog" \
     "${ROOT}/implementations/learnings" \
     "${ROOT}/implementations/.agents"
   touch "${ROOT}/implementations/.message-bus.jsonl" "${ROOT}/implementations/.review.txt"
   ```

2a. **Stale idle-monitor daemon cleanup.** Pre-3.12.0 monitors ran as `nohup`'d background daemons that survive M restarts; the new Monitor-tool model only works if any old daemon is killed first. This guard runs unconditionally each M startup (cheap stat + maybe one kill; idempotent once consumers upgrade and the file disappears):
   ```bash
   OLD_PID_FILE="${ROOT}/implementations/.agents/manager-monitor.pid"
   if [ -r "$OLD_PID_FILE" ]; then
     OLD_PID=$(cat "$OLD_PID_FILE" 2>/dev/null | tr -d '[:space:]')
     if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
       # Verify the PID actually belongs to the old daemon before kill — guards
       # against PID reuse on a busy machine. Match `manager-monitor` (wrapper)
       # or `python3` (child after exec); anything else, treat as stale.
       CMD=$(ps -o comm= -p "$OLD_PID" 2>/dev/null || true)
       case "$CMD" in
         *manager-monitor*|*python3*) kill -TERM "$OLD_PID" 2>/dev/null || true; sleep 1 ;;
         *) : ;;
       esac
     fi
     rm -f "$OLD_PID_FILE"
   fi
   ```

3. **Version check.** Read `${ROOT}/implementations/.version` — plain text, single line, a semver string like `2.1.0`. Compare to M's target (from the "Plugin version" section above):

   - **Missing `.version`, no prior `buses/` dir, no other `implementations/` content** → fresh install. Skip to step 5.
   - **Missing `.version` but `buses/` exists OR there are pre-existing stories/plans/etc.** → this is a pre-v2 project. Run the migration playbook (step 4) with "from = < 2.0.0".
   - **`.version` equals target** → no migration. Skip to step 5.
   - **`.version` is older than target** → run the migration playbook (step 4) with the exact from-version.
   - **`.version` is newer than target** → print a warning as direct text output ("project `.version` is `<X>`, newer than this plugin's `<Y>` — install a newer `claude-wow` or re-point the project at an older version") and **stop the turn**. Do not touch anything; do not proceed to Phase 2.

4. **Migration playbook.** **Run this entire step ONLY if `.version` differs from target (per step 3's branching). Skip to step 5 otherwise — migration table is not loaded unless actively migrating.** Before any destructive step, confirm with the human via `AskUserQuestion`:

   > "This project is on WOW v`<from>`; upgrade schema to v`<target>`? I'll perform the steps below and commit them as a workflow-artifact commit."
   >
   > Options: `Yes, migrate (Recommended)` / `Dry-run (show planned changes only)` / `Abort (leave project as-is)`.

   On `Dry-run`, print the planned steps and re-ask. On `Abort`, stop the turn.

   When the human approves, apply the transforms for the from→target pair:

   **Migration table lives at `docs/superpowers/migrations/manager-schema-migrations.md`.** Read it on-demand (only when actively performing this migration playbook), apply the row(s) for your from→target pair, then drop the content from working context. Do NOT load the file in routine session start. The file's top has an LLM-instruction directive enforcing the on-demand-only / forget-after-use discipline; honor it. New stories add their migration row at the bottom of that file (one row per story); this command file no longer carries the table inline.

   After transforms, write the new version to `.version` (overwrite):
   ```bash
   printf '%s\n' "2.33.6" > "${ROOT}/implementations/.version"
   ```

   Commit the migration as a single standing-authority workflow-artifact commit (subject: `chore: migrate WOW schema <from> → <target>`). See "Standing authority" below.

   **After-migration restart reminder (introduced in v`2.27.3`).** When the human approves the migration, M emits the following to the human as direct text output (NOT a bus message — the human is the audience):

   > "Heads up: restart any currently-running peers (PP/SD/T/Slacker) so they pick up the new prompt — `/reload-plugins` does not restart running sessions."

   See "After a major migration" subsection below for the full reload-plugins / in-context-prompt mismatch story + version-mismatch detection logic.

   ### After a major migration (introduced in v`2.27.3`)

   `/reload-plugins` refreshes the plugin cache (the source the next NEW agent session reads from) but does NOT restart agents already running in the session. Each running agent has its old prompt loaded in-context and continues old behavior even after the new prompt is on disk.

   Operationally:
   - **Plugin cache** (`~/.claude/plugins/cache/<repo>/claude-wow/<sha>/commands/*.md`): refreshed by `/reload-plugins`.
   - **Running agent in-context prompt**: pinned at session start; not refreshed by `/reload-plugins`.

   M can detect a prompt-version mismatch by comparing a running agent's `hello` payload (if it includes a version) to the current `.claude-plugin/plugin.json` `version`. If they disagree, M emits a `nudge` to that agent ID asking it to exit + restart, and a direct text output to the human flagging the mismatch.

   Otherwise: at any major migration the human SHOULD restart all peers — `bye` from each, then re-launch via slash commands. New sessions read the refreshed cache.

5. **Trim aged messages on the bus (opportunistic).** Drop lines older than 24h, atomic-rewrite via `.tmp` + `mv` — but only when the bus is large enough to be worth the inode swap. Default threshold is 2000 lines, tunable per-project via `${ROOT}/implementations/.bus-trim-threshold` (single integer). Below the threshold, skip the trim entirely; in a typical session the bus stays under 2000 lines and trim runs maybe once a day instead of every 5 minutes:
   ```bash
   BUS="${ROOT}/implementations/.message-bus.jsonl"
   THRESHOLD_FILE="${ROOT}/implementations/.bus-trim-threshold"
   THRESHOLD=2000
   [ -f "$THRESHOLD_FILE" ] && THRESHOLD=$(cat "$THRESHOLD_FILE" | tr -d ' \n')
   LINES=$(wc -l < "$BUS" 2>/dev/null | tr -d ' '); LINES=${LINES:-0}
   if [ "$LINES" -ge "$THRESHOLD" ]; then
     CUTOFF=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
     jq -c --arg cutoff "$CUTOFF" 'select(.ts >= $cutoff)' "$BUS" > "$BUS.tmp" && mv "$BUS.tmp" "$BUS"
   fi
   ```

6. **Initial stale-file sweep.** For each `${ROOT}/implementations/.agents/*.json`, parse the agent ID from the filename. If a `bye` message for that ID exists in the (post-trim) bus, or the file's mtime is older than 24 hours, `rm` it.

   **Stale role-marker sweep (introduced in v`2.33.2`).** Also call Story 049's helper to drop `.claude/.session-role-by-claude-pid/<pid>` markers whose claude PID is no longer in `ps` (e.g., agent crashed without running its release-marker exit ceremony):
   ```bash
   source "${ROOT}/scripts/whats-my-role.sh"
   wow_sweep_stale_role_markers
   ```

7. **Auto-cleanup of stale merged feat-branches.** Standing authority — no `AskUserQuestion`. Delete branches matching ALL four criteria:
   1. Branch name matches `feat/<NNN>-*` (enforced by iterating `refs/heads/feat/`).
   2. `git merge-base --is-ancestor <branch> ${CANONICAL_BRANCH}` (= reachable from canonical, hence merged in some form — handles squash + merge-commit + rebase).
   3. Branch tip commit older than 3 days.
   4. Corresponding worktree (if present) has no uncommitted changes.

   ```bash
   NOW_TS=$(date +%s)
   THREE_DAYS_AGO=$((NOW_TS - 259200))
   DELETED_BRANCHES=()
   for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/feat/); do
     git merge-base --is-ancestor "$branch" "${CANONICAL_BRANCH}" 2>/dev/null || continue
     TIP_TS=$(git log -1 --format=%ct "$branch" 2>/dev/null) || continue
     [ "$TIP_TS" -lt "$THREE_DAYS_AGO" ] || continue
     WORKTREE_PATH=$(git worktree list --porcelain | awk -v b="$branch" '
       /^worktree / {wt=$2}
       /^branch refs\/heads\// {if (substr($2, 12) == b) print wt}
     ')
     if [ -n "$WORKTREE_PATH" ]; then
       [ -z "$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null)" ] || continue
       git worktree remove "$WORKTREE_PATH" 2>/dev/null
     fi
     git branch -D "$branch" >/dev/null 2>&1 && DELETED_BRANCHES+=("$branch")
   done
   [ "${#DELETED_BRANCHES[@]}" -gt 0 ] && echo "M auto-cleanup: deleted ${#DELETED_BRANCHES[@]} stale merged feat branch(es): ${DELETED_BRANCHES[*]}"
   ```

   Anything failing one of the four criteria still requires `AskUserQuestion` per the existing branch-deletion policy. The new authority is purely additive over the existing ask-first guard.

8. **Backlog promotion coherence check (introduced in v`2.24.2`).** Scan `implementations/backlog/*.md` for files where line 1 contains `<!-- status: accepted -->`. For each such file, grep `implementations/stories/*.md` for the line `Source backlog: implementations/backlog/<basename>` (the convention SD uses in plan + story Cross-ref blocks).

   ```bash
   MISMATCHES=()
   for bf in "${ROOT}/implementations/backlog/"*.md; do
     [ -f "$bf" ] || continue
     st=$(head -1 "$bf" | grep -oE 'status: [a-z-]+' | awk '{print $2}')
     [ "$st" != "accepted" ] && continue
     bn=$(basename "$bf")
     if grep -lE "Source backlog: implementations/backlog/${bn}" "${ROOT}/implementations/stories/"*.md 2>/dev/null | head -1 | grep -q .; then
       MISMATCHES+=("$bn")
     fi
   done
   ```

   If `${#MISMATCHES[@]}` > 0, emit `AskUserQuestion`:

   > "Found ${#MISMATCHES[@]} backlog items still marked `accepted` despite having corresponding stories filed. Auto-promote them?"
   > Options: `Auto-promote (Recommended)` / `List them, I'll review` / `Skip`.

   **Auto-promote path:** for each mismatch, M derives the story id + slug from the matching story file's basename, then invokes `bash scripts/file-story-from-backlog.sh --promote-only <backlog-id> <story-id> <story-slug>`. Bundle all flips into one commit `chore: backfill backlog promotion (coherence repair)`.

9. **Version coherence repair (introduced in v`2.25.0`).** Sprint-mode PRs are version-stamped at merge time by `scripts/sprint-merge-bump.sh` (see Phase 3 step 5 + Section A in `docs/superpowers/specs/2026-05-02-version-cascade-fix-design.md`). When a human bypasses the wrapper and merges via the GitHub UI / `gh pr merge` directly, main can land in a state where:

   - `.claude-plugin/plugin.json` `version` ≠ this file's "Plugin version" literal, OR
   - latest migration-row "to" version ≠ either of the above, OR
   - any of the three contains `<NEXT` (placeholder leaked through).

   On startup, M reads all three:

   ```bash
   PJ_V=$(jq -r '.version' "${ROOT}/.claude-plugin/plugin.json")
   MGR_V=$(grep -oE 'plugin version \*\*\`[0-9]+\.[0-9]+\.[0-9]+\`' "${ROOT}/commands/manager.md" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
   ROW_V=$(grep -E '^\s*\| `[0-9]+\.[0-9]+\.[0-9]+` → `[0-9]+\.[0-9]+\.[0-9]+`' "${ROOT}/commands/manager.md" | tail -1 | grep -oE '`[0-9]+\.[0-9]+\.[0-9]+`' | tail -1 | tr -d '`')
   ```

   If any disagree OR any contains `<NEXT`, emit `AskUserQuestion`:

   > "Version coherence check failed on `main`. Detected: plugin.json=v\<X\>, manager.md=v\<Y\>, migration-row.to=\<Z\>. Likely a manual merge bypassed the auto-merge wrapper. Repair?"
   > Options: `Repair (compute next version, stamp + commit)` / `Skip (leave as-is, will surface again)` / `Investigate manually`.

   **Repair path:** re-run the wrapper logic against `main` directly (no PR-branch dance) — read CUR from origin/main, compute NEXT per a default `version_bump_type: minor` (or prompt human via `AskUserQuestion` for the bump type), apply substitutions, commit + push as `chore: version coherence repair (manual-merge bypass)`.

10. **Update-availability check (introduced in v`2.33.8`).** Run `bash scripts/check-plugin-updates.sh nedati-technologies/claude-wow-plugin` once per session. Capture stdout. If output matches the line `update-available <local> <latest> <url>`, print to the human as direct text output (NOT a bus message — informational only):

    > ⚡ Plugin update available: claude-wow `v<installed>` → `v<latest>`. Run `/reload-plugins` after upgrading. Release notes: `<URL>`.

    Stamp tracker `last_update_check_ts` to now-ISO regardless of outcome (helper success, no-update, or graceful skip on gh failure). Non-blocking — M continues to Phase 2 immediately. Network/auth failures are silent (the helper handles via stderr-only diagnostic). One-shot per session — not re-checked on subsequent ticks.

11. **Read token-discipline doctrine.** `cat commands/_token-discipline.md`. Skip silently if absent.

## Phase 2 — Peer (coordination)

Because M starts first, typically no peers are up when this phase begins. Your job is to check, prompt the human to launch any missing peers, and re-check.

1. **Ping each core peer role.** Generate a temporary preflight ID `manager-preflight-<YYYYMMDDTHHmmss>-<6hex>` (don't create a `.agents` file for it — it's ephemeral; format mirrors the canonical agent-id grammar so the MCP server's `from` regex accepts it). Append three `ping` messages to the bus, one per core role, each with a unique nonce payload:

   For each core role (`senior-developer`, `pair-programmer`, `tester`), call `mcp__claude-wow__bus_emit` with a unique nonce payload. Tool args:

   ```json
   {
     "from": "manager-preflight-<YYYYMMDDTHHmmss>-<6hex>",
     "type": "ping",
     "to": "<role>-*",
     "payload": "pf-<8hex>"
   }
   ```

   Then `sleep 120` — two minutes, generous on purpose. Note: `from` carries an ephemeral preflight ID following the canonical `<role>-<YYYYMMDDTHHmmss>-<6hex>` grammar with role `manager-preflight` (the role enum allows hyphens, so `manager-preflight` is a valid role-prefix). The MCP server validates and atomically appends each ping.

   Also ping `slacker-*` if this project has a `<!-- slacker-bridge-config -->` block in `implementations/learnings/slacker.md` (signals S is expected).

2. **Read responses.** Look for `pong` messages on the bus whose `in_reply_to.ts` matches each ping's ts. A role is **alive** iff at least one matching `pong` arrived.

3. **Clean unresponsive peer files.** For each core role with no pong: `rm` every `${ROOT}/implementations/.agents/<role>-*.json` for that role. Those agents are gone.

4. **Decide next step:**

   - **All three core roles alive** → Phase 2 complete. Go to Phase 3.
   - **One or more missing** → prompt the human via `AskUserQuestion`. Paste the current status into the question body, then offer options:

     > "Waiting for core peers: **`<comma-separated missing roles>`**. Open a new terminal for each and run the matching slash command (`/pair-programmer`, `/senior-developer`, `/tester`). S is optional (Slack integration). When the peers have printed their startup banners, pick Re-check."

     Options:
     - **Re-check (Recommended)** — loop back to step 1.
     - **Skip S and continue** — shown only when all three core roles are alive and only S is missing.
     - **Abort** — print the BIG ERROR block below and stop the turn.

   Repeat the loop until all core roles are alive or the human aborts. There's no automatic timeout — the human decides when to give up.

### BIG ERROR (human aborted peer-wait)

Print this as direct text output, not in a tool call:

```
═══════════════════════════════════════════════════════════════════════════
  ⚠ MANAGER ABORTED — peers not brought online
═══════════════════════════════════════════════════════════════════════════

  At abort time:
    [✗] Pair Programmer  — no active session detected
    [✓] Senior Developer — senior-developer-20260422T090328-9adeb6
    [✗] Tester           — no active session detected

  → Open a terminal for each missing role (e.g. /pair-programmer, /tester)
  → Then re-run /manager in this terminal.

═══════════════════════════════════════════════════════════════════════════
```

Mark each core role with `[✓]` (alive — show its ID) or `[✗]` (missing). Mark S as `[ ] Slacker (optional) — not active` if relevant. After printing, stop the turn.

## Phase 3 — Bootstrap (M's session)

Run only after Phase 2 has confirmed all core peers are alive.

1. **Claim role marker.** Source the central role-identification helper and claim the marker BEFORE any `AskUserQuestion` call (the PreToolUse hook gates AUQ on the marker existing):
   ```bash
   source "${ROOT}/scripts/whats-my-role.sh"
   wow_claim_role manager   # idempotent on same role; exit 2 on conflict
   ```
   Failure to claim is fatal for M (M's `AskUserQuestion` calls will be denied by the hook). On non-zero exit, escalate via direct text output.
2. **Generate your agent ID** per `_agent-protocol.md` (`manager-<YYYYMMDDTHHmmss>-<6hex>`). Print it to the human.
3. **Initialize your offset tracker** at `${ROOT}/implementations/.agents/<agent-id>.json`. Start `last_line` at the **current line count** of the bus (so you don't re-process history on boot):
   ```json
   {
     "last_line": <N>,
     "last_seen": "<now ISO>",
     "github_bridge_task_id": "<id returned by Monitor for the bridge spawn, or null>",
     "github_bridge_pid": "<integer PID read from .bridge-pid, or null>",
     "github_bridge_state": {},
     "triage_counts": {"actionable": 0, "not_actionable": 0, "already_addressed": 0},
     "last_user_prompt_ts": null,
     "auto_promote_paused_until": null
   }
   ```
   `github_bridge_task_id` is set in step 6 below if the bridge is spawned (null otherwise). `github_bridge_pid` (introduced in v2.9.0) is the bridge subprocess PID — read from `${ROOT}/implementations/.github/.bridge-pid` after spawn; used by the user-presence re-arm trigger (see "User-presence re-arm trigger" in bus message handlers). `github_bridge_state` (introduced in v2.9.0) is a `{<repo>: <latest-bridge-status-state-string>}` dict updated whenever a `bridge-status` event is observed on the bus. `triage_counts` (introduced in v2.4.0) counts PP triage outcomes for periodic human summaries. `last_user_prompt_ts` (introduced in v2.12.0) is the ISO timestamp of the most recent `<user-prompt-submit-hook>` event observed; auto-inits to `null`; consumed by the autonomous-pickup gate's AFK-signal check. `auto_promote_paused_until` (introduced in v2.12.0) is the ISO timestamp when M's global auto-promotion pause expires; auto-inits to `null`; set by the disapproval brake. `last_all_terminal_ts` (introduced in v2.21.0) is the ISO timestamp when all sprint items first reached terminal status; auto-inits to `null`; used by the Phase 4 retro-open trigger's 5-min fallback. `reviewers_closed` (introduced in v2.21.0) is a list of role names whose `review-closed` for the active sprint has been observed; auto-inits to `[]` at sprint kickoff; consumed by the Phase 4 retro-open trigger's conjunctive condition. `retro_open_fired` (introduced in v2.21.0) is a boolean idempotency flag for the Phase 4 trigger; auto-inits to `false`; set to `true` on the first `retro-open` emit (normal or fallback). **AFK-handling fields (introduced in v2.23.0):** `afk_active` is a boolean (auto-init `false`); `afk_mode` is `"idle" | "leader" | null` (auto-init `null`); `afk_started_ts` is `<ISO> | null` (auto-init `null`); `leader_decisions` is the audit-log list (auto-init `[]`); `last_afk_session_id` is the most recent AFK session id `<YYYYMMDDTHHmmss>-<6hex>` (auto-init `null`). All five are consumed by the AFK handling section above. **Spurious-wake fields (introduced in v2.24.0):** `bus_wake_bugs` is the aggregated list of spurious-wake reports from peers (auto-init `[]`); `last_bus_wake_bug_digest_ts` is the ISO timestamp when the digest last fired (auto-init `null`). Both are consumed by the "Spurious wake reporting" subsection. **PP-checkpoint field (introduced in v`2.30.0`):** `pp_checkpoints` is a ring buffer (last 10) of `pp-checkpoint` payloads received from PP at sprint-mode item boundaries (auto-init `[]`); each entry is `{ts, sprint_id, items_reviewed_so_far, open_reviews_now, last_finding_count_per_item, bus_cursor_line_number_observed}`. Consumed by PP on next session start for compaction-recovery state-seed (the most recent entry seeds PP's reconstruction). M appends on every `pp-checkpoint` observation and trims to 10 (drops oldest); see `pp-checkpoint` handler below for the append-and-trim logic. **Update-availability field (introduced in v`2.33.8`):** `last_update_check_ts` is the ISO timestamp of the most recent Phase 1 update-availability check (auto-init `null`); stamped on every M startup, never read for throttle (Story 057 design — startup-only, no periodic check).
4. **Emit `hello`** with `to: *` and a one-liner payload identifying you. Peers see "M is online."
5. **Arm ONE Monitor on the bus** through the shared filter script (see `_agent-protocol.md` → "Bus-tail filter script"). Use the `Monitor` tool with `persistent: true`, `timeout_ms: 3600000`, description `"M bus tail on <repo-name>"`. Substitute `<<AGENT_ID>>` with the ID you generated in step 1:

   ```bash
   ROOT="<<ROOT>>"
   BUS="$ROOT/implementations/.message-bus.jsonl"
   [ -f "$BUS" ] || touch "$BUS"

   CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
   BUS_TAIL=$(
     ls "$ROOT/.claude/scripts/wow-process/bus-tail.sh" 2>/dev/null \
     || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/bus-tail.sh 2>/dev/null | head -1
   )

   if [ -n "$BUS_TAIL" ]; then
     exec bash "$BUS_TAIL" "$BUS" "<<AGENT_ID>>" "manager"
   else
     echo "[bus-tail-armed-raw] $BUS (filter script not found; falling back to raw tail)"
     exec tail -F -n 0 "$BUS"
   fi
   ```

   Critical: use the **Monitor** tool, NOT Bash `run_in_background`. Monitor streams each stdout line to you as an event notification; background Bash would silently accumulate. When the script is found, irrelevant messages (peer-to-peer traffic addressed to other roles, self-echoes, malformed lines) are dropped at the OS level and never fire a Monitor event.

5a. **Arm the idle-monitor Monitor task.** Resolve the wrapper the same way as bus-tail / github-bridge (project-local override first, then plugin cache):
   ```bash
   CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
   IDLE_MONITOR_WRAPPER=$(
     ls "$ROOT/.claude/scripts/wow-process/idle-monitor.sh" 2>/dev/null \
     || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/idle-monitor.sh 2>/dev/null | head -1
   )
   ```
   Spawn with the `Monitor` tool: `persistent: true`, `timeout_ms: 3600000`, command `exec bash "$IDLE_MONITOR_WRAPPER"`, description `"idle monitor on <repo-name>"`. Record the returned task id as `idle_monitor_task_id` in your offset tracker (symmetric to `github_bridge_task_id`).

   The wrapper exec's `idle-monitor.py`, which watches `.activity.jsonl` every 60s; when all required wow-process roles have reached a `stop`/`stop_failure` state and `.nothing_to_do` is absent, the python prints one JSONL `all-idle-nudge` line to stdout. CC forwards each line as a task-notification on `idle_monitor_task_id`; M's Monitor-event handler (see `commands/manager.md` → "Idle-monitor events") dispatches on `from` prefix `idle-monitor-`. On receipt, see the `declare_idle` tool description for what to do.

   **Marker awareness:** When the user signals new work — assigning a story, asking "what's the status", or resuming after a quiet period — call `resume_work` before dispatching, in case `.nothing_to_do` is set from a previous session. The tool is idempotent so this is always safe.

6. **Arm the GitHub bridge** (introduced in v2.3.0). The bridge is a Python-stdlib subprocess that polls watched repos via `gh api` and emits PR-state + bridge-status events to its stdout, which Monitor forwards to your session. Decide what to do based on the project's `.github/` state, in this exact order:

   1. **`${ROOT}/implementations/.github/config.json` exists** → spawn the bridge via `Monitor`. Resolve the wow-process wrapper script path the same way the bus-tail script is resolved (project-local override first, then plugin cache):
      ```bash
      CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      BRIDGE_WRAPPER=$(
        ls "$ROOT/.claude/scripts/wow-process/github-bridge.sh" 2>/dev/null \
        || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/wow-process/github-bridge.sh 2>/dev/null | head -1
      )
      ```
      Spawn with `persistent: true`, `timeout_ms: 3600000`, command `exec bash "$BRIDGE_WRAPPER" --config "$ROOT/implementations/.github/config.json"`, description `"GitHub bridge on <repo-name>"`. Record the returned task ID as `github_bridge_task_id` in your offset tracker. The wrapper script handles PID-uniqueness check before exec'ing `python3 bridge/github/run.py`; on port collision it exits 2 with stderr — Monitor surfaces the failure and you escalate via `question` to the human.

      **Then read the bridge's PID** (introduced in v2.9.0; needed for the user-presence re-arm trigger). The bridge writes `${ROOT}/implementations/.github/.bridge-pid` within ~100ms of starting; retry up to 5× at 100ms intervals. Store the integer in `github_bridge_pid` in your tracker:
      ```bash
      BRIDGE_PID=""
      for i in 1 2 3 4 5; do
        if [ -f "$ROOT/implementations/.github/.bridge-pid" ]; then
          BRIDGE_PID=$(cat "$ROOT/implementations/.github/.bridge-pid" 2>/dev/null | tr -d '[:space:]')
          [ -n "$BRIDGE_PID" ] && break
        fi
        sleep 0.1
      done
      ```
      If the file never appears (5×100ms exceeded), proceed with `github_bridge_pid: null`. The user-presence trigger becomes a no-op for this session; the bridge's periodic re-arm timer is the safety net.
   2. **Else `${ROOT}/implementations/.github/disabled` exists** → skip the spawn silently. The human previously opted out. Leave `github_bridge_task_id` null.
   3. **Else (no config, no sentinel) — bridge dormant + non-blocking ask path:**
      - **Emit `status` to bus first** via `mcp__claude-wow__bus_emit` (the AFK-safety record — even if you sit blocked on the AskUserQuestion afterwards, the bus already records the dormant-bridge state and how the human can resolve it). Tool args:

        ```json
        {
          "from": "<your-agent-id>",
          "type": "status",
          "to": "*",
          "payload": "github bridge config not yet provided; bridge dormant this session. Human can answer the AskUserQuestion to enable, write ${ROOT}/implementations/.github/config.json directly, or say 'skip github bridge permanently' to write the sentinel and stop being asked."
        }
        ```
      - **Then emit `AskUserQuestion`** with header `"GitHub bridge"`, body explaining the bridge purpose, and three options matching the story's labels exactly: `Watch repo X` / `Skip GitHub watching for now` / `Skip permanently (write .github/disabled)`.
      - **Critical lifecycle note:** `AskUserQuestion` is a blocking tool with no native timeout. The story's "30-second soft timeout" is best-effort and depends on the human resolving the prompt. The pre-emit bus status above is what makes the session AFK-safe regardless of how long the AskUserQuestion sits — peers and future-M sessions know the bridge is dormant, and on the human's next interaction they can answer the question. Continue past Phase 3 only after the AskUserQuestion resolves.
      - **On answer:**
        - `Watch repo X`: follow up with `AskUserQuestion`s for `owner/name`, the port (default 47823 with three options + custom), and **`mode`** (default `Polling (every 30s)` with `Webhook (real-time, requires gh extension install cli/gh-webhook + admin on the repo)` as the alternative; introduced in v2.5.0). Write `${ROOT}/implementations/.github/config.json` with `{"port": <port>, "repos": ["<owner/name>"], "polling_interval_sec": 30, "dedup_retention_days": 7, "mode": "<polling|webhook>"}`. Spawn the bridge per branch 1. Note: if the human picks webhook but the extension isn't installed or admin is missing, the bridge auto-falls-back to polling and emits `bridge-status: degraded` — no action required from you here, just relay the degraded message to the human if it appears.
        - `Skip GitHub watching for now`: do nothing on disk (the next M session will re-ask).
        - `Skip permanently (write .github/disabled)`: `mkdir -p "$ROOT/implementations/.github/" && touch "$ROOT/implementations/.github/disabled"`. Skip spawn.

7. **Survey current state:**
   - Read every story file in `implementations/stories/`. Group by `<!-- status: ... -->` line.
   - Read every backlog file in `implementations/backlog/`. Group by `<!-- status: ... -->` line.
   - Print a concise summary to the human: open stories (by status), backlog items, peer agents now online (IDs that ponged), oldest in-flight item.

After this, stand by for human input. Bus-tail, GitHub bridge, and idle-monitor Monitor tasks are event-driven and will push events to you when peers write to the bus, when the GitHub bridge sees a PR transition, or when peers go idle.

