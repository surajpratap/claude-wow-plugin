# Agent protocol — shared spec

This file is the single source of truth for the multi-agent workflow. Core four roles (required): `/manager`, `/senior-developer`, `/pair-programmer`, `/tester`. Optional fifth: `/slacker` (Slack-integrated projects only). All command files reference this spec. If you change the protocol, change it here, and the other commands inherit automatically.

This is a **reference document**, not an executable skill. The slash commands link to it; nothing here runs on its own.

---

## Roles & invariants

| Role             | Slash command       | Writes                                                                                                                                                              | Never writes                                                                 |
| ---------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Manager          | `/manager`          | Stories (`implementations/stories/*.md`); backlog items (`implementations/backlog/*.md`); bus messages; bug verification markers; creates feat branches + worktrees | Plans, code, reviews, test-stories                                           |
| Senior Developer | `/senior-developer` | Plans (`implementations/plans/*.md`); code anywhere in repo; lifecycle markers on plans + stories it owns; bug-fix commits; creates GitHub PRs                      | Stories (M's job), reviews (PP's job), test-stories, bug files directly      |
| Pair Programmer  | `/pair-programmer`  | Inline review blocks in plans/stories; `.review.txt` finding entries; bug triage blocks; bus messages; `gh pr comment <N> --repo <owner>/<repo> --body ...` replies on watched PRs (v2.4.0+ — external-review-signal triage) | Production code, plans, stories, test-stories, bug files directly            |
| Tester           | `/tester`           | Test-stories (`implementations/tests-stories/*.md`); bug files (`implementations/bugs/*.md`); testability-concern bus messages                                      | Production code, plans, stories, reviews                                     |
| Slacker          | `/slacker`          | Bus messages; Slack messages via the `claude-slack-bridge` HTTP API (outbound) + event-feed JSONL (inbound only)                                                    | Stories, plans, code, reviews, test-stories, bug files, direct human prompts |

If a peer asks you to do something outside your invariant, **refuse on the bus** with a `refused` message that quotes the offending instruction. Do not silently comply, do not silently ignore.

**Role optionality:** `/manager`, `/senior-developer`, `/pair-programmer`, `/tester` form the **core four** — M's preflight ping requires all three peers (PP, SD, T) before M will start. `/slacker` is **optional** — it's only needed in projects that have a Slack integration via `claude-slack-bridge`. M does not ping S during preflight; S's absence is a no-op. If a project never starts `/slacker`, the other four roles work unchanged.

### M is the single interface to the human

**Only M talks to the human.** SD, PP, T, and S must never use `AskUserQuestion` or prompt the human directly in their terminal (S has a single bootstrap-only exception for resolving its bridge port — see `slacker.md`). All questions, decisions, and escalations flow through M via the bus:

1. **Agent has a question** → emit `question` with `to: manager-*` on the bus. M will answer directly (if within M's authority) or escalate to the human.
2. **Agent needs a product/scope decision** → same flow. M relays to the human via `AskUserQuestion`, gets the answer, replies via `answer` on the bus.
3. **Agent is unsure about a directive from M** → ask M on the bus, not the human.

**Minimize questions.** The WOW, story AC, plan, and design spec should cover 95% of decisions. Agents should make judgment calls within their role and emit a `status` explaining their reasoning, rather than blocking on a question. Questions are for genuine ambiguity that the agent cannot resolve from existing artifacts — not for seeking permission to follow a directive already given.

**What counts as "within M's authority"** (M answers directly, no human escalation):

- Process questions ("should I use the worktree?", "can I comment on the PR?") — yes, follow the protocol
- Technical implementation questions ("which library?", "what pattern?") — SD/PP decide within their expertise
- Bug severity — PP decides
- Scope questions ("is this in-scope for the story?") — M checks the AC and answers

**What requires human escalation** (M uses AskUserQuestion):

- Product direction changes ("should we support X?")
- Wont-fix decisions on story AC items
- Scope expansions not covered by existing stories
- Trade-offs where reasonable people could disagree and the human's preference matters

---

## Project-root discovery

Every command, on startup, derives the project root with:

```bash
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

All paths in this spec are relative to `${ROOT}`.

---

## Agent IDs

Format: `<role>-<YYYYMMDDTHHmmss>-<6hex>`

- `<role>`: `manager` | `senior-developer` | `pair-programmer` | `tester` | `slacker`
- `<YYYYMMDDTHHmmss>`: UTC timestamp at session start (e.g. `20260416T162200`)
- `<6hex>`: 6 random hex characters

Example: `manager-20260416T162200-a4f9e2`

The agent ID is generated **once per session** at startup, written to the bus in a `hello` message, and printed to the human so they can reference it.

**Hello payload version convention.** Peer hello payloads SHOULD include `Plugin v<X.Y.Z>` somewhere in the payload (string OR `payload.note` field) so M's hello-mismatch detector (see `commands/manager.md` `hello` event handler) can detect cross-agent version drift after `/reload-plugins` + role-file edits. Soft convention — missing version is handled gracefully (drift check skipped silently). Existing peer prompts already do this organically; this convention formalizes it so the regex extraction stays stable.

---

## File layout

```
${ROOT}/
  implementations/
    stories/                    # M writes here              (3-digit: 001-slug.md)
    plans/                      # SD writes here             (3-digit: 001-slug.md)
    tests-stories/              # T writes here              (4-digit: 0001-slug.md)
    bugs/                       # T writes bug files, M+PP add review markers, SD adds fix notes
                                #                             (4-digit: 0001-slug.md)
    backlog/                    # M-ONLY. Backlog items M tracks for future brainstorms.
                                # Other agents read-only; they suggest via `backlog-suggest`
                                # bus messages and M decides.
                                #                             (3-digit: 001-slug.md)
    learnings/                  # per-role persistent learnings (one file per role)
      manager.md                # M reads at startup + updates when learning
      senior-developer.md       # SD reads at startup + updates when learning
      pair-programmer.md        # PP reads at startup + updates when learning
      tester.md                 # T reads at startup + updates when learning
      slacker.md                # S reads at startup + updates when learning (if S is active)
    .review.txt                 # PP writes code-level findings here
    .message-bus.jsonl          # the one shared message bus; all agents read and write here
    .agents/                    # per-session offset trackers
      <agent-id>.json           # { "last_line": N, "last_seen": "<iso>", ... }
  .worktrees/                   # per-story isolated working trees. Gitignored.
                                # M creates on story-creation; torn down after PR is merged.
```

`.message-bus.jsonl` and `.agents/` should be added to `.gitignore` if you don't want bus history in version control. (For MVP, keeping them tracked is fine — useful for debugging.)

### Storage locations: project vs. home (introduced in v2.14.0)

- **Project state** (per-repo, runtime, tied to the codebase): under `${ROOT}/implementations/` as documented above. Bus, agent trackers, GitHub bridge config, stories/plans/bugs.
- **User state** (per-user, cross-project, not for git): under `~/.wow-kindflow/`. Slack tokens, future API keys, user preferences. Managed exclusively via `scripts/wow-storage.sh` (mode 0700 dirs, mode 0600 files, atomic-rename writes). Per-project sub-keys are derived from `git rev-parse --show-toplevel`.

The full convention, helper API, bootstrap flow, and migration playbook live in `commands/manager.md` `# Home-dir storage` section. Consuming agents (S, future bridges) call `wow_storage_get` to read, but routing for missing creds always goes through M (the human channel) — see `commands/manager.md` `# Interactive behavior → ## Cred bootstrap (home-dir)`.

---

## Agent learnings

Each role has a persistent learnings file at `implementations/learnings/<role>.md`. Multiple agents of the same type share one file (e.g. if three testers run, they all read/write `tester.md`). Learnings are NOT the same as Claude Code's built-in memory — they are project-scoped knowledge shared across all sessions and all users of this repo.

### What goes in learnings

- **Work guidelines** — process rules the agent has learned (e.g. "always check-in with concrete status, not just 'working'")
- **Human instructions** — standing directives from the human (e.g. "from now on ask me about X before doing Y")
- **Project domain knowledge** — facts useful across sessions (credentials, service ports, library quirks, schema conventions, seed data shapes)
- **Coding patterns** — conventions discovered during implementation that aren't in AGENTS.md (e.g. "Tiptap needs immediatelyRender:false in Next.js SSR")
- **Architecture decisions** — why things are the way they are (e.g. "bootcamp trainings reference library trainings, not separate entities")
- **Mistakes to avoid** — things that went wrong and how to prevent them (e.g. "jscpd inline ignores don't work with trailing text — use clean `// jscpd:ignore-start` only")
- **Project tooling** (PP and T record; SD reads) — discovered facts about the project's build/test/lint chain (duplicate detector name if any, lockfile format, test runner, pre-commit hook stack). Update when the project's manifest changes.

### What does NOT go in learnings

- Ephemeral task state (current story, in-flight bug) — that's on the bus + file markers
- Anything already in CLAUDE.md / AGENTS.md / the command files
- Story-specific details that won't apply to future stories

### When to READ learnings

- **At startup** — after reading CLAUDE.md + AGENTS.md + protocol + command file
- **After compaction** — the post-compact hook re-reads command files; learnings file should be read too
- **Before making a judgment call** — if unsure about a convention, pattern, or past decision, check learnings first
- **Before starting a new story** — refresh on patterns from prior stories

### When to WRITE learnings

Write a learning when you encounter something that the next agent in your role would benefit from knowing. Concrete triggers:

- **SD:** after discovering a library quirk, after a PP finding taught you a pattern, after a bug revealed a convention
- **PP:** after resolving a finding (the pattern behind it), after discovering a new code quality rule, after a jscpd decision
- **T:** after a bug revealed a testing gap, after discovering a seed data pattern, after learning what to check in browser tests
- **M:** after a human directive, after a process correction, after discovering a coordination pattern

**The test:** "If I was replaced by a fresh agent tomorrow, would they make the same mistake I just avoided?" If yes → write it down.

### Introspection phase (mandatory between stories)

After a story's PR is created and before M releases the next story, M initiates an **introspection phase**. This is a deliberate pause for all agents to reflect and capture learnings.

**Flow:**

1. **M emits `introspect`** with `to: *` (broadcast) and the story slug in the payload. One message on the bus.
2. **Each agent (SD, PP, T, M, optionally S) reflects** on the just-completed story by reviewing:
   - Their own messages and interactions on the bus during the story
   - Code changes and findings they raised/addressed
   - Bugs filed, fixed, or wont-fixed
   - What went well, what went wrong, what they'd do differently
3. **Each agent asks themselves:**
   - What did I learn?
   - What did I do correctly that I should repeat?
   - Where can I improve?
   - What should I remember about coding conventions, architecture, or domain?
4. **Each agent updates `implementations/learnings/<role>.md`:**
   - Add new learnings
   - Prune stale/outdated entries
   - Consolidate verbose entries into concise ones
   - Remove anything now covered by AGENTS.md or command files
5. **Each agent emits `introspection-done`** with `to: manager-*` and a one-line summary of what they added/changed.
6. **M waits for all active peers** to emit `introspection-done`, then proceeds to the next story.

**Introspection should be quick** — 1-2 minutes per agent. It's not a deep retrospective, it's a habit of capturing knowledge while context is fresh.


## Message bus

### Rationale

One shared append-only JSONL file; every agent reads and writes it; the `to` field addresses messages to specific agents or roles. Agents filter on read. No routing layer, no relay logic — peers address each other directly when the work is peer-to-peer (e.g. SD hands a plan to PP, PP triages a bug back to SD). M stays the orchestrator for human-facing and cross-role decisions (verifying bugs, triggering PRs, releasing queued stories), but it is not a message router.

### Path

`${ROOT}/implementations/.message-bus.jsonl`

### Format

One JSON object per line, UTF-8, terminated by `\n`. Each line must be a complete JSON object. Lines must be ≤4096 bytes for atomic Unix concurrent appends. For payloads larger than that, write the payload to a separate file and put the path in `ref` instead.

### Schema (every message)

| field         | type                | required | meaning                                                  |
| ------------- | ------------------- | -------- | -------------------------------------------------------- |
| `ts`          | ISO-8601 UTC string | yes      | message timestamp                                        |
| `from`        | string (agent ID)   | yes      | sender                                                   |
| `to`          | string              | yes      | agent ID, role-glob, or `*`                              |
| `type`        | string (enum below) | yes      | message kind                                             |
| `payload`     | string              | no       | free text (or stringified JSON for structured context)   |
| `ref`         | string              | no       | repo-relative path                                       |
| `in_reply_to` | `{ ts, from }`      | no       | previous message being replied to                        |

### `to` field syntax

- **Exact agent ID:** `manager-20260416T162200-a4f9e2` — reaches that one agent.
- **Role glob:** `manager-*`, `senior-developer-*`, `pair-programmer-*`, `tester-*`, `slacker-*` — reaches every active agent of that role.
- **Broadcast:** `*` — reaches everyone. Used sparingly (`hello`, `bye`, `introspect`).

A message addressed to `senior-developer-*` is consumed by every active SD session. In practice there's one per role, but the glob preserves that invariant explicitly.

### Message types

| type                    | purpose                                                                                                                                                                                     | typical sender → recipient(s)            |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `hello`                 | agent joined; payload may name the human-given purpose                                                                                                                                      | new agent → `*`                          |
| `bye`                   | agent leaving cleanly                                                                                                                                                                       | departing agent → `*`                    |
| `status`                | current activity narration (optional, terse)                                                                                                                                                | any → `manager-*` (usually) or `*`       |
| `nudge`                 | "please do X" — recipient should `ack`                                                                                                                                                      | any → role-glob or specific ID           |
| `ack`                   | acknowledging receipt of a nudge / question                                                                                                                                                 | recipient → sender                       |
| `question`              | direct question                                                                                                                                                                             | any → role-glob (usually `manager-*`)    |
| `answer`                | reply to a `question`; carries `in_reply_to`                                                                                                                                                | any → original sender                    |
| `refused`               | role-violation refusal; `payload` quotes the offending instruction                                                                                                                          | refuser → original sender                |
| `ping`                  | liveness probe; recipients must reply with `pong`                                                                                                                                           | any → role-glob (typically M at startup) |
| `pong`                  | liveness reply; always carries `in_reply_to` of the ping                                                                                                                                    | recipient → original sender              |
| `story-created`         | new story exists at `ref`. Payload carries worktree path. Sprint-mode dispatch may include an optional `in_flight: "<dispatched-count>/<concurrency_limit>"` string field — SD uses it as advisory pacing input; when `dispatched-count == concurrency_limit`, SD defers claim-and-implement until the current plan ships.    | M → `senior-developer-*`                       |
| `read-token-discipline` | Refresh signal — peers re-read `commands/_token-discipline.md` from disk. Auto-injected by the MCP server (`mcp/claude-wow-server/server.py`) on every `bus_emit` call where `type IN {"story-created", "sprint-kickoff"}`. Payload: `{path: "commands/_token-discipline.md", reason: "auto-injected after <type>"}`. Peers re-read the file on receipt; older peers (pre-v3.1.0) ignore the type gracefully. | <auto-injected by MCP server> → `*`     |
| `read-retro-doctrine` | Refresh signal — peers re-read `commands/_retro-doctrine.md` from disk. Auto-injected by the MCP server (`mcp/claude-wow-server/server.py`) on every `bus_emit` call where `type IN {"review-closed", "retro-open"}`. Payload: `{path: "commands/_retro-doctrine.md", reason: "auto-injected after <type>"}`. Peers re-read the file on receipt; older peers (pre-v3.2.0) ignore the type gracefully. | <auto-injected by MCP server> → `*`     |
| `compaction-occurred` | Signal that the agent's context was just compacted. Emitted by the `PostCompact` hook (`scripts/hooks/wow-post-compact-bus-notice.sh`) via the MCP server CLI shim, addressed to the agent itself. Payload: `{agent_id, role, ts}`. Agent's handler runs `scripts/wow-process/post-compact-restore.sh` to diff `role-process-map.json` against live PID files and re-arms any MISSING wrapped process via `scripts/wow-process/<purpose>.sh`. | hook (self-emit) → `<self-agent-id>`    |
| `plan-ready-for-review` | plan at `ref` ready for PP                                                                                                                                                                  | SD → `pair-programmer-*`                 |
| `plan-reviewed`         | PP added `<!-- reviewer-comment -->` block asking for changes                                                                                                                               | PP → `senior-developer-*`                      |
| `plan-approved`         | PP added `<!-- reviewer-approval -->` block to plan at `ref`                                                                                                                                | PP → `senior-developer-*`                      |
| `plan-done`             | implementation of plan at `ref` complete                                                                                                                                                    | SD → `pair-programmer-*` + `manager-*`   |
| `story-done`            | story at `ref` complete (all its plans done); T cue to start testing; PP performs holistic story-level review on receipt. Payload **may** include `role_files_updated: [<commands/*.md>...]` listing role-file paths the impl modified — peers (PP, T) consume on next session start to re-read their own role file when flagged. Payload **may** also include `expected_suite_count: <int>` when impl modified the test bench (new `tests/*.sh` file or new asserts in existing) — T asserts `tests/run-all.sh` reports exactly that count instead of inferring from version + preceding stories.                                                                                  | SD → `tester-*` + `manager-*` + `pair-programmer-*` |
| `story-verified`        | T ran the test-story for `ref` and no open bugs remain. M's trigger to nudge SD to create a PR. Payload **may** include `humanize_steps: [{step: <N>, do: "<action>", expect: "<observable>"}, ...]` — numbered manual verification steps T cannot automate (UI, external service, plugin runtime, cred bootstrap, migration UX). Omitted when T's automated coverage is sufficient. M relays per-story to human on completion; sprint-mode M aggregates across items into the Phase 4 retro digest.    | T → `manager-*`                          |
| `pr-created`            | SD created a GitHub PR for the story's feat branch. Payload includes the PR URL.                                                                                                            | SD → `manager-*`                         |
| `bug-found`             | T filed a new bug at `ref`. M scope-verifies, then emits `bug-verified`.                                                                                                                    | T → `manager-*`                          |
| `bug-verified`          | M confirmed the bug is in-scope and real; PP should triage.                                                                                                                                 | M → `pair-programmer-*`                  |
| `bug-triaged`           | PP added triage block, cleared for SD to fix.                                                                                                                                               | PP → `senior-developer-*`                      |
| `bug-fixing`            | SD picked up the bug, working in the story's worktree.                                                                                                                                      | SD → `tester-*` + `manager-*`            |
| `bug-fixed`             | SD pushed the fix to the story's branch. T to re-test.                                                                                                                                      | SD → `tester-*` + `manager-*`            |
| `bug-closed`            | T re-tested and the fix holds. Bug marked closed.                                                                                                                                           | T → `manager-*`                          |
| `testability-concern`   | T flags something in SD's in-flight work that will block testing (missing seed, hardcoded data, missing test-id hooks, nondeterminism). Advisory, non-blocking.                             | T → `senior-developer-*`                       |
| `worktree-released`     | T stepping out of the worktree so SD can fix a bug.                                                                                                                                         | T → `senior-developer-*`                       |
| `worktree-returned`     | SD finished editing in the worktree; T may resume.                                                                                                                                          | SD → `tester-*`                          |
| `introspect`            | M initiates the introspection phase between stories. All agents reflect and update learnings.                                                                                               | M → `*`                                  |
| `introspection-done`    | Agent completed introspection and updated their learnings file.                                                                                                                             | any → `manager-*`                        |
| `backlog-suggest`       | Peer suggests a backlog item to M (scope for a future story, tech debt, design consistency, etc). `payload` describes the item.                                                             | SD / PP / T → `manager-*`                |
| `pr-state`              | GitHub bridge — PR state transition. Payload: `{repo, pr, from_state, to_state, actor, url}`. States: `merged`, `closed`, `draft`, `ready_for_review`. Emitted on transitions only, never on initial cursor population. | github-bridge → `manager-*`              |
| `bridge-status`         | GitHub bridge — lifecycle / health signal. Payload: `{state, reason}`. States: `armed`, `polling`, `degraded`, `stopped`.                                                                  | github-bridge → `manager-*`              |
| `pr-review`             | GitHub bridge — review submitted on a watched PR. Payload: `{repo, pr, reviewer, state, body, url}` (state ∈ approved / changes_requested / commented). Bridge dedups by review.id. Introduced in v2.4.0. | github-bridge → `manager-*`              |
| `pr-comment`            | GitHub bridge — comment posted on a watched PR. Payload: `{repo, pr, author, body, url, kind}` (kind ∈ review_thread / issue_comment). Bridge emits one event per actual GitHub comment; M handles burst-collapse. Introduced in v2.4.0. | github-bridge → `manager-*`              |
| `triage-done`           | PP completed an external-signal triage (PR-comment or CI-failure). Payload: `{repo, pr, source_url, outcome, summary}` (outcome ∈ actionable / not_actionable / already_addressed / env_flake / test_update). The two newer values (`env_flake`, `test_update`) come from PP's CI-failure triage subsection added in v2.5.0. Introduced in v2.4.0. | `pair-programmer-*` → `manager-*`        |
| `review-closed`         | PP signals that no further `.review.txt` findings will be added for the active sprint. Payload: `{sprint_id, summary}`. M's Phase 4 retro-open trigger consumes it (see `commands/manager.md` Phase 4 trigger conjunctive condition + 5-min fallback). Sprint-mode-only; ignored outside sprints. Introduced in v2.21.0. | PP → `manager-*`                         |
| `bus-restored`          | M (or `bus-restore-helper`) signals the canonical bus has been restored / rewritten externally; peers should fast-forward their cursors to `payload.current_line_count` without emitting events for the gap. Payload: `{reason, current_line_count}`. Introduced in v2.22.0. | M / helper → `*`                         |
| `human-afk`             | M signals the human is AFK. Payload: `{mode, reason, in_flight_summary}`. Mode ∈ `idle` / `leader`. Informational; peers don't act. Introduced in v2.23.0. | M → `*`                                  |
| `human-back`            | M signals the human has returned. Payload: `{previous_mode, duration_seconds, decisions_count}`. Informational; peers don't act. Introduced in v2.23.0. | M → `*`                                  |
| `leader-decision`       | M logs a Leader-mode autonomous decision (informational mirror of the audit-log entry). Payload: `{decision, reasoning, scope}`. Peers don't act. Introduced in v2.23.0. | M → `*`                                  |
| `bus-wake-bug`          | Any peer reports a spurious Monitor wake (a bus line that should have been suppressed by the cursor mechanism or role-glob filter but wasn't). Payload: `{offending_line, reason, role, agent_id, timestamp}`. M aggregates in offset-tracker `bus_wake_bugs[]` for periodic human digest. Introduced in v2.24.0. | any peer → `manager-*`                    |
| `pp-checkpoint`         | PP emits at sprint-mode item boundaries (after observing each `story-shipped` or `pr-state: merged`) so M can persist PP's live cursor state for compaction-recovery. Payload: `{items_reviewed_so_far: [<id>...], open_reviews_now: [<id>...], last_finding_count_per_item: {<id>: <count>}, bus_cursor_line_number_observed: <int>}`. Sprint-mode-only; ignored outside sprints. M maintains a ring buffer in offset-tracker `pp_checkpoints` (last 10). | PP → `manager-*`                         |
| `retro-learnings-window-open` | M signals start of the per-peer learnings-refresh window at sprint-end Phase 4 (after retro.md synthesis, before action-items-to-backlog). Payload: `{sprint_id, deadline_ts}`. Sprint-mode-only. | M → `*`                                  |
| `learnings-updated`     | Peer reports updating their own `implementations/learnings/<role>.md` during the sprint-end refresh window. Payload: `{path, sha_before, sha_after, summary}`. Sprint-mode-only; M aggregates count into retro digest. Silence is correct when no stale facts found — peer emits nothing in that case. | any peer → `manager-*`                   |
| `skill-question`        | Peer-invoked superpowers skill needs a human-facing question routed through M (per Story 046's prompt-level override — same pattern M uses for `superpowers:brainstorming`). Payload: `{question_id, skill, question, options, context_excerpt}`. `question_id` is a peer-generated nonce used by `skill-answer.in_reply_to` for correlation. Sprint-mode and steady-state.                                                                                                              | any peer → `manager-*`                   |
| `skill-answer`          | M's response to a `skill-question`; payload: `{answer, in_reply_to: <question_id>}`. Routed back to the originating peer agent ID.                                                                                                                                                                                                                                                                                                                                                | M → originating peer ID                  |
| `ci-check`              | GitHub bridge — CI check-suite state transition on a watched PR. Payload: `{repo, pr, sha, suite, status, conclusion}` where status ∈ `queued` / `in_progress` / `completed` and conclusion (when status=completed) ∈ `success` / `failure` / `cancelled` / `skipped` / `neutral` / `timed_out`. Bridge dedups by per-suite-id `{status, conclusion}` comparison (a single suite transitions queued → in_progress → completed on the same id; a max-id cursor would silently drop the second / third transitions — see story AC). Introduced in v2.5.0. | github-bridge → `manager-*`              |
| `behavioral-change-flag` | SD signals an in-progress impl is about to land a protocol-level / cross-role behavioral change in a directive file (typically `commands/_agent-protocol.md` or load-bearing role-file sections). PP is the gate: SD pauses commit until PP returns `behavioral-change-cleared`. Payload: `{file: <path>, summary: <one-line>, change_kind: <"protocol-types" \| "role-authority" \| "tool-rename" \| "lifecycle-marker" \| "other">, plan_ref: <plan path>}`. Used to surface protocol changes for explicit PP awareness ahead of impact (avoids "PP discovers the protocol changed at PR review time"). | SD → `pair-programmer-*`                 |
| `behavioral-change-cleared` | PP signals they have inspected the in-progress protocol change and have no blocking concerns. SD may proceed with the commit. Payload: `{in_reply_to: <flag ts>, comments: <optional one-line>}`. Absence of this message after a `behavioral-change-flag` means PP is still inspecting; SD must wait. | PP → `senior-developer-*`                |

### Bridge events (non-peer emitters)

The `pr-state` and `bridge-status` events are emitted by `bridge/github/run.py` (introduced in v2.3.0), a Python-stdlib subprocess M spawns at Phase 3. v2.4.0 added `pr-review` and `pr-comment`; v2.5.0 added `ci-check`. The bridge writes all of these to **stdout** — they reach M via the GitHub bridge Monitor (a separate Monitor task from the bus-tail Monitor) and are NOT written to `${ROOT}/implementations/.message-bus.jsonl`. Bus-file consumers (peer agents) never see bridge events directly.

The `from` field on bridge events follows a non-role convention: `github-bridge-<port>` (e.g. `github-bridge-47823`). This is how M's Monitor handler discriminates bridge events from peer bus events: `from.startsWith("github-bridge-")` ⇒ bridge event ⇒ route per the bridge-event policy in `commands/manager.md`. M alone consumes bridge events; if a triage or fan-out is warranted, M emits a normal peer-bus message (`nudge`, `status`, etc.) into the bus file.

The bridge stays stateless — one event per source row, dedup by `review.id` / `comment.id` / per-suite `{status, conclusion}`, no in-process buffering. **Burst-collapse is M-side**: M buffers `pr-comment` events keyed by `(pr_url, author)` and flushes via `ScheduleWakeup(60s)` into a single `nudge` to PP. The 60s burst window is hardcoded in M's prompt.

v2.5.0 also introduces optional **webhook mode**. When `${ROOT}/implementations/.github/config.json` has `mode: "webhook"`, the bridge probes for the `cli/gh-webhook` extension (`gh webhook` is **not** built into the gh CLI — install via `gh extension install cli/gh-webhook`) and admin permission on each watched repo. If both are present, the bridge opens a local HTTP listener on `127.0.0.1:<port>` and runs `gh webhook forward` per repo as a child process. Webhook deliveries flow through the **same** per-event helpers + per-PR `threading.Lock`s as polling, so dedup is identical regardless of ingress path. Polling stays armed at a slower cadence (default 5min) as a safety net, and any forwarder that exits prematurely is restarted up to 3 times with 30s backoff before that repo falls back to polling-only. Missing extension or missing admin transparently degrades the bridge with explicit `bridge-status: degraded` events — webhook mode is best-effort, polling-only is always the safe baseline.

### Bus-tail filter script

Every agent's bus-tail Monitor is invoked through a shared shell script that pre-filters the stream at the OS level — so Claude Code only receives messages actually addressed to the running agent. Self-echoes, peer-to-peer traffic intended for another role, and malformed lines never fire a Monitor event.

- **Location in the plugin:** `scripts/bus-tail.sh`. Resolve its absolute path the same way the protocol file is resolved (project-local override first, then plugin cache):
  ```bash
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  BUS_TAIL=$(
    ls .claude/scripts/bus-tail.sh 2>/dev/null \
    || ls -t "$CLAUDE_DIR"/plugins/cache/*/claude-wow/*/scripts/bus-tail.sh 2>/dev/null | head -1
  )
  ```
- **Signature:** `bus-tail.sh <bus-path> <agent-id> <role>`. `<role>` is one of `manager` | `senior-developer` | `pair-programmer` | `tester` | `slacker`.
- **Forward predicate** (ALL must hold): line parses as JSON, `from != <agent-id>`, and `to` is `"*"` OR exact `<agent-id>` OR `"<role>-*"`.
- **Fallback:** if the resolver returns an empty `BUS_TAIL`, the agent's Monitor command falls back to raw `tail -F -n 0 "$BUS"` and relies on the in-session filter in the Reading protocol below. Functionally identical, just noisier (every bus write triggers a Monitor event the agent then discards).
- **Requirements:** `bash`, `tail`, `jq` 1.6+. All are standard dev-machine tools.

### Reading protocol

The filter script already drops lines you shouldn't act on, so in most cases every line the Monitor delivers is one you must process. Still, apply the same predicate in-session as a safety net — the script may be missing on older installs or stale caches, and a belt-and-suspenders check costs nothing.

1. On startup, count current bus lines: `wc -l < ${ROOT}/implementations/.message-bus.jsonl` (treat as 0 if file missing). Store as `last_line` in `${ROOT}/implementations/.agents/<agent-id>.json`. New sessions typically start at the current tail — M and most peers skip historical lines. SD and T may start at `0` to catch up on unfinished stories (their command files specify).
2. On every wake (Monitor event, scheduled tick, human turn): read lines `[last_line+1 .. EOF]`. Parse each as JSON. **Filter** to messages where `from != <your agent ID>` AND `to` matches self:
   - `to === "*"` → keep
   - `to === "<your exact agent ID>"` → keep
   - `to === "<your role>-*"` (e.g. `senior-developer-*`) → keep
   - otherwise → skip
3. Act on each kept message in order. Update `last_line` to the current line count after processing. Never delete or rewrite bus lines — the bus is append-only.

### Writing protocol

Append a single JSON line to the bus file. Always include `ts`, `from`, `to`, `type`. Keep lines under 4KB.

```bash
BUS="${ROOT}/implementations/.message-bus.jsonl"
mkdir -p "$(dirname "$BUS")"
printf '%s\n' "$(jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg from "$AGENT_ID" \
  --arg to "senior-developer-*" \
  --arg type "story-created" \
  --arg ref "implementations/stories/022-training-completion.md" \
  --arg payload "Story ready. Worktree at .worktrees/022-training-completion/." \
  '{ts:$ts, from:$from, to:$to, type:$type, ref:$ref, payload:$payload}')" \
  >> "$BUS"
```

If `jq` is unavailable, any tool that produces a single valid JSON line works (e.g. `python3 -c 'import json,sys; print(json.dumps({...}))'`).

### Optional sprint-mode fields (introduced in v2.10.0)

Sprint-aware messages may include two optional fields:

- `sprint_id`: string, format `YYYY-MM-DD-<short-topic-slug>`. Identifies the sprint this message belongs to. `null` (or omitted) for non-sprint traffic.
- `item_id`: string, typically the manifest item id (often the backlog/story number `001`-`999`). Identifies the manifest item this message refers to. `null` (or omitted) for sprint-level events like `retro-open`.

Existing handlers continue to work — both fields are additive, optional, and ignored by handlers that don't know about sprint mode. Sprint-aware peers route on these fields to disambiguate concurrent item streams.

### Self-echo discipline

Every agent tails the same file, which means your own writes come back at you. The bus-tail filter script (above) drops self-echoes before Claude Code ever sees them. As a safety net for the unfiltered-fallback path, in-session readers still skip any line where `from === <your agent ID>` after updating `last_line`.

---

## Liveness

Each agent's hook router (`plugin/scripts/hooks/log-activity.sh`) writes one JSONL row to `implementations/.activity.jsonl` per registered hook event: `PreToolUse`, `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionStart`, `SessionEnd`. Schema: `{ts, claude_pid, role, type, tool?, text?}`.

A long-running idle-monitor at `plugin/scripts/wow-process/idle-monitor.sh` (started by M as a Monitor-tool task alongside bus-tail and the GitHub bridge) checks every 60s: for each live wow-process PID in the required set (`manager, senior-developer, pair-programmer, tester`), is its most recent activity row's `type` in `{stop, stop_failure}`? If yes and `implementations/.nothing_to_do` is absent → print one JSONL `all-idle-nudge` line to stdout; CC forwards to M as a Monitor-task notification (not a bus message — M-private signal stays out of `.message-bus.jsonl`).

`.nothing_to_do` is a sticky do-not-disturb marker, written by the `declare_idle` MCP tool and cleared by `resume_work`. Both are M-only; the conversation surface (Claude's response text after the tool call) is the user-facing signal that no-work mode changed state.

**Liveness use:** M's `run_liveness_round()` and Team-idle check also consult the activity log BEFORE ping-based liveness; ping is invoked only for roles with no recent activity-log signal. See `commands/manager.md` "Pre-sleep liveness round → Activity-log first" subsection.

---

## Lifecycle markers

Machine-parseable HTML comments inside story and plan files. They don't render in markdown previews but `grep` finds them instantly.

### Story files (`implementations/stories/<NNN-slug>.md`)

Filenames carry a 3-digit zero-padded sequence prefix so `ls` shows stories in creation order (e.g. `001-add-healthcheck.md`). M picks the number at creation time (max existing prefix + 1). Plans inherit the story's `NNN-slug` exactly; a second plan under the same story uses `NNN.2-slug.md`, `NNN.3-slug.md`, etc. Full rules live in `manager.md` → **Filename convention**.

- **Line 1:** `<!-- status: backlog -->` (initial). Owner: SD updates this as work progresses (`backlog` → `in-progress` → `in-review` → `done`). M reads it but never modifies it.
- **On completion**, SD appends at the bottom:
  ```
  <!-- story-done @ YYYY-MM-DD by <agent-id> -->
  <one-line summary of what shipped>
  <!-- /story-done -->
  ```

### Plan files (`implementations/plans/<slug>.md`)

- **Line 1:** `<!-- status: drafting -->` (initial). Owner: SD updates (`drafting` → `in-review` → `approved` → `implementing` → `done`). PP reads but never modifies this line.
- **PP review blocks** (existing convention):
  ```
  <!-- reviewer-comment @ YYYY-MM-DD -->
  ...
  <!-- /reviewer-comment -->
  ```
  and
  ```
  <!-- reviewer-approval @ YYYY-MM-DD -->
  ...
  <!-- /reviewer-approval -->
  ```
- **On implementation complete**, SD appends:
  ```
  <!-- plan-done @ YYYY-MM-DD by <agent-id> -->
  <one-line summary>
  <!-- /plan-done -->
  ```

### Test-story files (`implementations/tests-stories/<NNNN-slug>.md`)

Owned by T. 4-digit zero-padded sequence number, independent from the 3-digit story/plan namespace. Test-stories are loosely 1:1 with stories but not required to be — T can add scenario-specific extras (e.g. `0007-org-crud-edge-cases.md`).

- **Line 1:** `<!-- status: draft | ready | running | passed | failed -->` (T updates).
- **Header lines** (near the top):
  ```
  Story: implementations/stories/<NNN-slug>.md
  Branch: feat/<NNN-slug>
  Worktree: .worktrees/<NNN-slug>/
  ```
- **Body:** prose test procedure in numbered steps. For web flows, describe what to click / expect; for APIs, paste the `curl` (or bun fetch) invocation. Steps should be re-runnable by a future tester with zero context.
- **On completion**, T appends:
  ```
  <!-- test-run @ YYYY-MM-DD by <agent-id> -->
  <one-line summary: pass / N bugs found, link to each>
  <!-- /test-run -->
  ```
  Subsequent runs append additional `<!-- test-run -->` blocks; don't delete history.
- For stories with no web/api surface (pure refactor, config), the file can be a one-liner: "No manual exercise — automated suite covers it."

### Bug files (`implementations/bugs/<NNNN-slug>.md`)

Owned by T for creation; M and PP add status-update markers; SD adds fix notes.

- **Line 1:** `<!-- status: reported | verified | triaged | fixing | fixed | closed | wont-fix -->`. Lifecycle owner per state:
  - `reported` → T (initial filing)
  - `verified` → M (scope check passed)
  - `triaged` → PP (severity + suggested angle assigned)
  - `fixing` → SD (picked up, working in worktree)
  - `fixed` → SD (fix pushed to the story branch in the worktree)
  - `closed` → T (re-tested, fix holds)
  - `wont-fix` → M (human decided not to fix)
- **Header lines**:
  ```
  Story: implementations/stories/<NNN-slug>.md
  Plan: implementations/plans/<NNN-slug>.md
  Branch: feat/<NNN-slug>
  Worktree: .worktrees/<NNN-slug>/
  Found-via: implementations/tests-stories/<NNNN-slug>.md   (optional)
  Severity: blocker | major | minor | nit                     (PP sets on triage)
  ```
- **Body sections** (T's initial filing):

  ```
  ## Reproduction
  <numbered steps>

  ## Expected
  <what should happen>

  ## Actual
  <what happens — paste outputs, screenshots, stack traces>

  ## Environment
  <dev seed used, API base URL, browser, any setup relevant to reproducing>
  ```

- **M verification marker** (added when M sets `verified`):
  ```
  <!-- verified-by-m @ YYYY-MM-DD by <agent-id> -->
  <one-line note: in-scope for story NNN; real bug vs expected; forwarding to PP>
  <!-- /verified-by-m -->
  ```
- **PP triage marker**:
  ```
  <!-- triage @ YYYY-MM-DD by <agent-id> -->
  Severity: <blocker|major|minor|nit>
  Suspected-area: <file/module>
  Suggested-angle: <shape of the fix; don't write the code>
  <!-- /triage -->
  ```
- **SD fix marker** (added when SD sets status to `fixed`):
  ```
  <!-- fix @ YYYY-MM-DD by <agent-id> -->
  Commit: <sha on feat/NNN-slug>
  Worktree: .worktrees/<NNN-slug>/
  <one-line summary of the root cause + fix>
  <!-- /fix -->
  ```
- **T close marker** (added when T sets status to `closed`):
  ```
  <!-- closed @ YYYY-MM-DD by <agent-id> -->
  Re-tested in .worktrees/<NNN-slug>/ at commit <sha>; reproduction no longer triggers.
  <!-- /closed -->
  ```

### Cross-references (human-readable, not authoritative)

- Every plan starts with a `Story:` line pointing to its parent story path.
- Every story can list its derived plans in a `## Plans` section that SD keeps current.
- Every test-story points back to its parent story; every bug points back to story + plan + branch + worktree.
- The authoritative linkage is the bus message thread (`story-created` → `plan-ready-for-review` → `plan-done` → `story-done` → `story-verified` + bug sub-threads `bug-found` → `bug-verified` → `bug-triaged` → `bug-fixed` → `bug-closed`).

---

## Commit safety — never discard other agents' changes

**This is a critical rule.** When committing in a worktree (or anywhere), agents must:

1. **Run `git status` before committing.** Review every modified/untracked file.
2. **Never discard changes you didn't author.** If you see changes from another agent (e.g. PP's review artifacts, T's test files, SD's code), commit them. Do not `git checkout -- <file>`, `git restore`, or `git reset` to remove them.
3. **If unsure about a change, ask on the bus first.** Emit a `question` to the likely author: "I see changes in `<path>` — are these yours? Should I commit them?" Wait for a response before discarding anything.
4. **Think four times before removing.** The logic "these aren't my changes so I'll revert them" is the single most common way AI agents destroy work. A worktree will eventually be torn down — any uncommitted change is **lost forever**. Default to committing everything.
5. **When story work is complete, commit ALL changes in the worktree.** `git add -A` in the worktree is acceptable at story-done time (unlike on main, where selective staging is required). The entire worktree belongs to the story.

The only exception: runtime state files (`.message-bus.jsonl`, `.agents/*.json`) should not be committed from worktrees — those belong to the main repo.

---

## Concurrency rules

- **One agent per role per project.** The bus assumes a single Manager, single Senior Developer, single Pair Programmer, single Tester per repo. Running two of the same role simultaneously is undefined behavior — they'll race on file edits and double-process bus messages.
- **Atomic line-append constraint.** Keep individual JSONL lines under 4096 bytes (POSIX `PIPE_BUF` floor). Above that, concurrent appends can interleave bytes within a single line.
- **No locking.** Bus is append-only; readers tolerate the file growing under them.

---

## Bus obedience rules

Every command must:

1. **Read-before-act.** Before claiming a piece of work, read the bus tail to check if a peer has already claimed or completed it.
2. **Obey in-role nudges.** Respond to `nudge` messages addressed to you (or your role-glob) within your role's invariant. Emit `ack` on receipt before starting work.
3. **Refuse out-of-role requests.** Quote the offending instruction in the `payload` and emit `refused`. The peer needs to know.
4. **Idempotency.** Before acting on a nudge, check lifecycle markers — if the work is already done, reply with `ack` + `status` describing the existing state, don't redo.
5. **Filter your own echoes.** Your own writes appear back on your Monitor. Drop lines where `from === <your agent ID>`.

---

## Liveness and stale-file cleanup

Mtime on `.agents/<agent-id>.json` is **not** a reliable liveness signal — files left behind by a force-killed terminal look fresh for several minutes. Liveness is verified by an explicit **ping/pong** handshake.

### Liveness check (used by Manager at startup, can be re-run anytime)

1. The checker emits a `ping` with `to: <role>-*` (e.g. `pair-programmer-*`, `senior-developer-*`, `tester-*`). The `payload` is a unique nonce so responses are easy to match.
2. Within ~120 seconds, every active agent matching that role-glob must reply with a `pong` carrying `in_reply_to: { ts, from }` of the ping.
3. After waiting (typically 120 seconds), the checker reads bus tail and counts `pong`s by `in_reply_to`.
4. For each `.agents/<id>.json` whose role matches a pinged role: if no `pong` from that ID arrived → the agent is **stale**. Delete the file.

### Stale-file cleanup (M's responsibility, runs at M's startup)

A `.agents/<id>.json` file is **stale** if any of:

- A `bye` message for that agent ID exists in the bus (clean exit), OR
- A `ping` was sent for the agent's role and no matching `pong` came back within 120s, OR
- File mtime is older than 24 hours (catastrophic safety net).

Stale files should be `rm`'d. The bus is never modified.

### Activity windows (used for nudge escalation, not for liveness)

After M has confirmed peers are alive at startup, ongoing activity is tracked by recency of bus messages from that peer:

- 60 min since the agent's last message: M may emit a `nudge` asking "status?".
- 2 hr after a nudge with no response: M re-runs the liveness check on that agent. If it fails, M cleans the file and informs the human.

### On clean exit

Each agent should:

1. Emit `bye` on the bus with `to: *`.
2. `rm` its own `.agents/<id>.json` file (best-effort — failure is fine, M will clean it later).

If the terminal is force-killed (Ctrl-Q, window close), neither of these runs. M's startup ping/pong recovers from this.

---

## Backlog

Backlog items live at `implementations/backlog/<NNN-slug>.md` and are **M-only** — the same ownership boundary as stories. Peers must not create, edit, or move backlog files directly. If an agent sees something that belongs in the backlog (tech debt noticed mid-impl, design-consistency gap, future-feature idea, inconsistency that doesn't block the current story), they emit a `backlog-suggest` bus message to `manager-*` and M decides whether to file it.

**Format:** same 3-digit zero-padded naming as stories (`NNN-slug.md`). Separate number namespace from stories — backlog starts at `001`. When a backlog item graduates to a real story, M brainstorms it fresh and writes a new story file; the backlog file can either be deleted (if fully captured in the story) or kept as historical context with a note pointing at the story.

**Content:** briefer than stories — no formal AC. Enough for a future M session to understand what was proposed and decide when to pick it up.

```markdown
<!-- status: proposed -->
<!-- concern: hygiene | robustness | feature | architecture -->
<!-- size: tiny | small | medium | large -->

# <Short title>

## What

<1-3 sentences describing the item>

## Why

<the trigger: which story/context surfaced this, what's the risk/cost of not doing it>

## Size / shape (rough)

<small / medium / large; notes on what it touches>

## Suggested-by

<agent-id or "human">, <date>
```

**Concern + size markers (introduced in v2.12.0).** Every backlog file MUST include both markers immediately after `<!-- status: ... -->`. Bucket definitions:

- **Concern** — `hygiene` (cleanup, naming, dead code), `robustness` (bug fixes, error handling, flake elimination), `feature` (new capability), `architecture` (core protocol contracts, schema migrations, role-boundary changes).
- **Size** — `tiny` (single file, <20 lines), `small` (~20-80 lines), `medium` (~80-250 lines + one regression test), `large` (250+ lines, multiple tests, plan-review surface).

M sets both at filing; PP/T verify presence on review. Items missing markers fail validation in `tests/manager-autonomy-gate.sh` and are ineligible for M's autonomous pickup. Markers are used by M's autonomous-pickup gate (`commands/manager.md` → "Cron lifecycle" → "Autonomous pickup") and by M's concern-aware backlog presentation when asking the human to pick items.

**Auto-promotion markers (introduced in v2.12.0).** When M auto-promotes a backlog item to a story without asking the human (under the 5-condition gate), three additional HTML-comment markers appear:

- On the auto-promoted **story file** (near line 1):
  ```
  <!-- auto-promoted-by-m @ <ISO> -->
  <!-- auto-promoted-from-backlog: NNN -->
  ```
- On the **source backlog file** (only set if the human disapproved an auto-promotion, per the disapproval brake):
  ```
  <!-- auto-promote-cooldown: until <ISO> -->
  ```
  Live cooldown means the source backlog item is ineligible for re-auto-promotion until the timestamp passes (default 30 days from disapproval).

**Lifecycle states (line 1):**

- `proposed` — new, waiting for M's review
- `accepted` — M agrees it belongs on the backlog
- `promoted` — graduated to a real story (record story number in the file)
- `dismissed` — M decided it's not needed (record why)

---

## Environment dependencies (T-owned env check)

Some agents have external-tooling dependencies the repo itself doesn't pin — browser automation, language servers, local services. T owns the "exercise the running product" surface and therefore owns the env check for browser tooling. This section defines the startup handshake.

### T's required env

- **Official Playwright MCP server** — the `playwright` plugin is a hard dependency of `claude-wow` (declared in `.claude-plugin/plugin.json`), so Claude Code auto-installs it and its bundled `.mcp.json` registers the MCP server; the `browser_*` tools surface as `mcp__plugin_playwright_playwright__browser_*`. T runs a startup **health-check** via a loose `ToolSearch` query (e.g. `playwright browser navigate`). If no matching tool surfaces, the plugin is present but the MCP server (launched via `npx @playwright/mcp@latest`) failed to start — a host/runtime problem (`node` missing, or no network for the `npx` fetch), NOT a missing install. T emits a `question` to `manager-*` — NOT to the human — reporting the runtime failure and its likely cause. T does **not** fall back to any other browser automation stack; without a working Playwright MCP, browser testing is paused.
- **`bun` + `curl`** (standard Unix / project-installed) — for API smoke tests. Should be present from the repo's normal dev setup.

### Env-dep install handshake

When T detects a missing or non-functional required dep on startup:

1. T emits `question` to `manager-*`: payload must name the dep, state why T needs it, cite which browser / API testing capability is blocked, and list the exact host-side fix (for a Playwright MCP runtime failure, the likely fix is installing `node` or restoring network so `npx @playwright/mcp@latest` can launch — the `playwright` plugin itself auto-installs and needs no manual registration).
2. M reads the ask. For a Playwright MCP runtime failure (plugin present, server not responding), the fix is host-side — `node` install / network — which happens outside T's process space, so M relays to the human via `AskUserQuestion`. M does **not** install anything itself; T's job was to declare the requirement, M's job is to unblock.
3. Human registers / installs, then tells M. M relays back to T via `answer`. T re-checks and proceeds.
4. If the dep is NOT on the approved env list (T wants something else the WOW hasn't blessed), M treats it as any unapproved dep: AskUserQuestion to the human first, no auto-approve.

T never installs deps itself. T never edits `.claude/settings.json` (that's tooling-config territory, AGENTS.md rule 10).

### Browser testing stack

Browser flows in test-stories use the `mcp__playwright__*` toolset exclusively — the official Microsoft Playwright MCP server. The Chrome MCP extension path is **deprecated** as of 2026-04-19 and must not be used in new test-stories; existing test-stories that reference it are historical artifacts (do not retro-edit them). Common Playwright MCP tools T will reach for: `browser_navigate`, `browser_click`, `browser_type`, `browser_snapshot`, `browser_take_screenshot`, `browser_console_messages`, `browser_close`.

---

## Project tooling discovery (PP startup)

Inspect the project's manifest (`package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod`) on first run for:

- **Duplicate detector** — a dependency like `jscpd` or similar, or a script that invokes one. Record the tool name in PP's learnings on first run. PP's "layout duplication → ignore, business logic → modularize" rule applies whenever a detector is configured. If none, PP still flags duplication organically during review.
- **Pre-commit / lint-staged / hooks chain** — so agents know what fires on commit. Record in learnings on first run.

Re-discover only when the manifest changes.

---

## Bug lifecycle

The bus thread for a single bug:

```
T files bug file + emits bug-found (to: manager-*).
M reads file, checks scope + reality, appends verified-by-m marker, sets status: verified,
  emits bug-verified (to: pair-programmer-*).
PP reads bug, appends triage marker (severity + suspected-area + suggested-angle), sets
  status: triaged, emits bug-triaged (to: senior-developer-*).
SD acks, enters .worktrees/<NNN-slug>/, sets status: fixing, emits bug-fixing (to:
  tester-* + manager-*). Fixes the bug, commits on feat/<NNN-slug> in the worktree,
  appends fix marker, sets status: fixed, emits bug-fixed (to: tester-* + manager-*).
T refreshes the worktree (git pull — the branch tip advanced), re-runs the reproduction.
  Fix holds → appends closed marker, sets status: closed, emits bug-closed (to: manager-*).
  Fix doesn't hold → adds a new bug (separate file, cross-refs the original) OR re-opens
  by reverting status to verified and explaining in a new marker block.
```

Rules:

1. **T files; M verifies; PP triages; SD fixes; T re-tests.** No role jumps its lane.
2. **One file per bug.** If a bug has two root causes, that's two bug files.
3. **Severity is PP's call** (set during triage). T can suggest in the reproduction section, but doesn't decide.
4. **`wont-fix` is M-only** and requires a human sign-off in the bus thread. Bug stays in `implementations/bugs/` as history.
5. **All bugs for a story must be `closed` or `wont-fix`** before T emits `story-verified`. Until then, the story is not actually done even if SD emitted `story-done`.

---

## Worktree rules

M creates the story's worktree at story-creation time. SD, PP, and T all work inside it. M stays on `main`.

- **Path:** `.worktrees/<NNN-slug>/` at repo root. Gitignored. One worktree per story.
- **Branch:** always `feat/<NNN-slug>` — M creates both the branch and the worktree immediately after writing the story.
- **Creation (M's job):** after committing the story file on `main`, M runs:
  1. `git branch feat/<NNN-slug>` (from current main HEAD — so the story file is included in the branch)
  2. `git worktree add .worktrees/<NNN-slug> feat/<NNN-slug>`
  3. Emits `story-created` with the worktree path in the payload so SD/PP/T know where to work.
- **Who works where:**
  - **M** — always on `main`. Writes stories, orchestrates via the bus, edits `implementations/` artifacts from the main repo.
  - **SD** — works in `.worktrees/<NNN-slug>/`. Writes plans (in the worktree's `implementations/plans/`), implements code, commits on `feat/<NNN-slug>`.
  - **PP** — monitors `.worktrees/<NNN-slug>/` for file changes. Reviews code + plans from the worktree context. Writes review artifacts (`implementations/.review.txt`, plan review blocks) from the main repo's `implementations/`.
  - **T** — works in `.worktrees/<NNN-slug>/`. Tests the feature, files bugs (in main repo's `implementations/bugs/`). Runs dev servers from the worktree.
- **Teardown:** after the PR is created and the story is complete, M or T runs `git worktree remove .worktrees/<NNN-slug>`. Branch persists on the remote (it's the PR's source branch).

### Bug-fix coordination within the shared worktree

SD and T both work in the same worktree. When SD needs to fix a bug:

1. T emits `worktree-released` (to: `senior-developer-*`). T stops editing files in the worktree until SD is done.
2. SD makes the fix, commits on `feat/<NNN-slug>` inside the worktree.
3. SD appends the `<!-- fix -->` marker to the bug file (in the **main** repo's `implementations/bugs/`).
4. SD emits `bug-fixed` (to: `tester-*` + `manager-*`) + `worktree-returned` (to: `tester-*`).
5. T resumes testing.

The `worktree-released` / `worktree-returned` handshake prevents concurrent edits. One SD + one T, no filesystem locking needed.

### Where files live in the worktree model

- **Source code** (`apps/`, `packages/`): SD edits in `.worktrees/<NNN-slug>/`. Each worktree has its own checkout at the branch tip.
- **Implementation artifacts** (`implementations/stories/`, `implementations/plans/`, `implementations/tests-stories/`, `implementations/bugs/`, `implementations/.message-bus.jsonl`, `implementations/.agents/`): the bus and agent trackers live in the **main repo only** — every agent reads/writes the main repo's `.message-bus.jsonl`. Story files live on main (M writes them there). Plans are written by SD in the worktree's `implementations/plans/` and committed on the feat branch. Bug files are written by T in the main repo's `implementations/bugs/`.
- **Bug files**: T creates them at the main repo's `implementations/bugs/NNNN-slug.md`. SD reads from the main repo when picking up a bug. The `<!-- fix -->` marker SD adds to a bug file is done in the main repo too.

### Story completion — GitHub PR (not merge)

After the full test + fix + triage cycle, when T emits `story-verified`:

1. M nudges SD to create a GitHub PR.
2. SD runs `gh pr create` from the worktree (which is on `feat/<NNN-slug>`). Pushes the branch to origin first if needed.
3. SD emits `pr-created` (to: `manager-*`) with the PR URL in the payload.
4. **All agents comment on the PR.** When `pr-created` lands on the bus, every agent adds a comment to the PR via `gh pr comment <PR-number> --body "..."` with their perspective on the story:
   - **SD** — implementation summary: what was built, key decisions made, known trade-offs, dependencies added.
   - **PP** — review summary: findings raised and resolved, any open findings, code quality notes, jscpd status.
   - **T** — test summary: test-story path, bugs found and resolved, wont-fixes (with rationale), areas not covered, regression risks.
   - **M** — story summary: human decisions made during the story (scope changes, wont-fixes, deferred items), link to story + plan + spec files.
5. M notifies the human with the PR URL. **This marks the end of the story workflow.** The PR is merged by the human (or via GitHub review process), not by the agents.
6. After the PR is merged, M or T tears down the worktree.

---

## Sprint mode (introduced in v2.10.0)

Sprint mode is a blessed-batch autonomy mode where M drives a set of accepted backlog items to ship after a deep human + M brainstorm. The full flow lives in `commands/manager.md` "Sprint mode" section. This section documents the cross-cutting protocol additions: the manifest schema and the helper scripts.

### Sprint manifest schema

`implementations/sprints/<sprint-id>/manifest.json`. Sprint id format: `YYYY-MM-DD-<short-topic-slug>`.

```json
{
  "id": "2026-05-01-bridge-hardening",
  "started_ts": "2026-05-01T13:35:00Z",
  "started_by": "human",
  "status": "brainstorm | kickoff | active | paused | complete | aborted",
  "concurrency_limit": 3,
  "auto_merge": true,
  "budget": {
    "max_blockers": 1,
    "max_items": null,
    "max_minutes": null
  },
  "items": [
    {
      "id": "022",
      "story": "implementations/stories/022-home-dir-convention.md",
      "spike": null,
      "alt_story": null,
      "depends_on": [],
      "branch": "feat/022-home-dir-convention",
      "pr_url": null,
      "plan_approved_at": null,
      "status": "pending | spike-running | dispatched | in-review | merged | parked | rejected | shipped"
    },
    {
      "id": "021",
      "story": "implementations/stories/021-slack-bridge-bun.md",
      "spike": "implementations/spikes/021-bun-vs-npm-spike.md",
      "alt_story": "implementations/stories/021-slack-bridge-npm-alt.md",
      "depends_on": ["022"],
      "branch": "feat/021-slack-bridge-bun",
      "stacked_on": "feat/022-home-dir-convention",
      "pr_url": null,
      "plan_approved_at": null,
      "status": "pending"
    }
  ],
  "rebases": [
    {"ts": "2026-05-01T14:10:00Z", "parent": "022", "child": "021", "old_sha": "...", "new_sha": "..."}
  ],
  "blockers": [
    {"ts": "...", "item": "021", "kind": "rebase-conflict", "details": "..."}
  ],
  "retro_path": "implementations/sprints/2026-05-01-bridge-hardening/retro.md"
}
```

Validate any manifest with `scripts/sprint-manifest-validate.sh <manifest-path>` — exits 0 on valid, non-zero with diagnostic on stderr if invalid. M's Phase 1 manifest assembly step runs this against its own draft before showing the GO-signal `AskUserQuestion`.

**`plan_approved_at` (introduced in v2.19.0):** ISO timestamp set by M when PP emits `plan-approved` for the item. Auto-inits to `null`. Used by `scripts/sprint-graph-next-dispatchable.sh` as the gating condition for stacked-child dispatchability — children of a parent only become dispatchable once the parent's plan is approved (so that the child's branch can be created from the parent's commits-bearing tip rather than the kickoff sha). See `commands/manager.md` "Reacting to plan-approved (sprint mode)" for the M-side behavior. Items in older manifests without this field are treated as `null` by the script, which keeps stacked children gated until M sets it.

### Sprint helper scripts

- `scripts/sprint-manifest-validate.sh <manifest>` — schema validator. Validates id format, status enum, item required fields, depends_on cross-references, spike/alt_story pairing, rebases entries.
- `scripts/sprint-rebase-cascade.sh <parent-branch> <child-branch> <child-pr> <child-worktree> <manifest> <old-parent-sha> [parent-id] [child-id]` — performs a single child cascade after a parent merges. `<old-parent-sha>` is the parent's tip BEFORE the merge — captured by M's prompt via `git rev-parse <parent-branch>@{1}` (reflog) and passed in. Exit codes: 0 on success, 2 if child worktree is dirty, 3 on rebase conflict, 4 on push rejection, 5 on `gh pr edit` failure.
- `scripts/sprint-graph-next-dispatchable.sh <manifest>` — prints the items dispatchable RIGHT NOW (status=pending, deps satisfied per the dependency-graph rule, within `concurrency_limit` minus in-flight count), one id per line.

The scripts are the source of truth; M's prompt invokes them and emits bus messages on each result.

---

## Out of scope (not in this MVP)

- Cross-project bus (each repo has its own).
- Bus rotation / archival beyond M's opportunistic trim (24h cutoff, applied only when the bus exceeds N≈2000 lines; tunable via `implementations/.bus-trim-threshold`).
- Two agents of the same role running simultaneously.
- Authenticated messages (any process with write access can append anything; trust the filesystem).
- Rich observability tooling — `tail -f implementations/.message-bus.jsonl | jq .` is the dashboard.
