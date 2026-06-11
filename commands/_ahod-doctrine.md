# AHOD doctrine — All Hands On Deck mode

A team mode for crunch throughput: every agent — M included — owns one work item end-to-end in parallel. The serial relay (SD plans → PP reviews → T verifies) is suspended; each owner self-drives the full lifecycle in its own worktree, and the human's PR merge is the final cross-check. M stays the coordinator — relaying questions, unblocking, reassigning, mirroring state — while working its own item.

AHOD is entered and exited ONLY by explicit human signal (the `/ahod` and `/ahod-off` meta commands, run in M's terminal). It persists across sessions until revoked.

## Activation & state

- Source of truth: `implementations/config.json` — `{"schema": 1, "mode": "default" | "ahod", "ahod": {"activated_ts": "<iso>", "assignments": {"<role>": "<story ref>"}}}`.
- Read/write via `bash "$(wow-locate scripts/wow-config.sh)" get|set|del <jq-path>` — never hand-edit. M is the only writer. A missing file means `mode` is `default`.
- Assignments are keyed by ROLE (agent IDs rotate per session). Find yours: `wow-config.sh get .ahod.assignments.<your-role>`.
- Startup prints `env: mode=ahod` while the mode is active — on seeing it, read this file plus your assignment before resuming any work.
- Sprint mode and AHOD are mutually exclusive: no AHOD kickoff while a sprint manifest is `status: "active"`, and no sprint while `mode` is `ahod`.

## Kickoff (M + human)

1. Pool: M inventories accepted backlog items plus items the human names; together they agree an ordered queue. If the consuming project's AGENTS.md defines an external tracker, M mirrors pool selection there — M alone holds tracker write access.
2. Foundation brainstorm: per item, M settles the would-be mid-flight forks with the human (approach, surface, constraints) via targeted `AskUserQuestion` rounds; decisions land in each story stub under a `## Foundations` section.
3. Stubs: M authors story stubs for the FULL pool and commits them to the canonical branch in one commit — numbers claimed atomically, foundations captured while the human is present.
4. Worktrees: M creates `feat/$TEAM/<NNN-slug>` + `.worktrees/<NNN-slug>/` per item — the standard story-creation mechanics.
5. Assignments: M writes `ahod.assignments` — one item per role, M taking an interruptible item itself (management preempts).
6. M broadcasts `ahod-kickoff` to `*` (payload: pool, assignments, doctrine path), then emits one `story-created` per peer owner — addressed to the exact agent ID, payload `ahod: true`. M does not self-dispatch; its own assignment is recorded in the broadcast and config.
7. Each peer re-reads this doctrine plus its assignment, then emits `ahod-ack` to `manager-*` (`{role, ts}`) within 5 minutes. Silence → M's standard liveness machinery.

## Owner lifecycle (every owner, M included)

1. `ack` the dispatch.
2. Premise verification — next section. Never plan a stale item.
3. Plan: invoke `superpowers:writing-plans`; the plan lives in your worktree on the feat branch (standard plan location). Run the standard plan-shape gates. No review relay — emit one `status` to `manager-*` ("plan committed: <ref>") and proceed.
4. Implement: `superpowers:test-driven-development`, in your worktree. Standard commit conventions; never bypass hooks.
5. Gate: the project's full test/lint suite green in your worktree, then `superpowers:verification-before-completion`. Hard gates stay hard — anything the project marks human-approval-gated (schema changes, new dependencies, irreversible migrations) routes through M BEFORE you proceed.
6. Self-review: run the `code-review` skill on your own diff BEFORE opening the PR; fix what it finds; emit a `status` with the outcome. If a `code-review-request` reaches you after `pr-created` and you have not reviewed yet, run it then — before asking for merge.
7. Rebase onto the canonical branch, push, open the PR (standard branch + title conventions). The PR body notes "AHOD self-reviewed" plus a findings summary.
8. Emit `pr-created` to `manager-*` (payload includes `base` + url). That is your done-for-owner signal — M assigns your next item.
9. Introspect-lite: update `implementations/learnings/<your-role>.md` with anything durable. No team-wide introspect barrier between items.
10. Merge fallout preempts: when M routes PR feedback or CI failures for your item to you, it takes priority over your next item until that PR merges.

## Premise verification (before planning, in your worktree)

- Defect-typed item: reproduce the defect at the current canonical HEAD. Already fixed or not reproducible → emit `status` to `manager-*` with the evidence; M closes or replaces the item.
- Feature-typed item: confirm the named surface (file, app, component) exists and matches the story's evidence. Mismatch → same path.
- Trust evidence over summaries: when the story cites a source (log, message, screenshot), verify against the source itself before building on it.

## Question routing

- NEVER ask the human directly — the standing hard rule; M is the only human channel.
- Decide-and-report: technical, reversible forks within the story's Foundations + AC → decide, emit a `status` with a one-line rationale, keep moving.
- Escalate via M: product / scope / schema / dependency / irreversible forks → `question` to `manager-*`. M answers within its authority or relays to the human. While waiting, continue only sub-tasks the answer cannot invalidate.

## Refusal & override

An assigned item that violates your role's hard rules → `refused` to `manager-*` quoting the rule it violates. M reassigns, or returns the same dispatch carrying the human's explicit override quoted VERBATIM in the payload `override` field. An override is per-item, never standing. With an override present, proceed — your role's standing duties still timeslice first (Role notes).

## Role notes

- S: comms-first timeslicing — inbound Slack handling keeps its responsiveness; the dev item fills the gaps. Worktree work never blocks comms.
- T: full owner; apply your testing instincts to your own item inside the gate step. No test-stories for others' items.
- PP: no standing review duties — no `.review.txt` sweeps, no triage relay. Your review judgment goes into your own item.
- SD: unchanged craft, minus the relay waits.
- M: dual duty — see below.

## Suspended in AHOD

- The plan review relay: `plan-ready-for-review`, `plan-reviewed`, `plan-approved`.
- The story handoff chain: `story-done`, `story-verified` — replaced by your gate + `pr-created`.
- The bug relay for own-item defects (`bug-found` → `bug-verified` → `bug-triaged` → `bug-fixing` → `bug-fixed` → `bug-closed`) — fix your own defects inline. A defect you find in merged or others' work → `backlog-suggest` to `manager-*`.
- `code-review-request` routing to PP — it routes to the PR author instead.
- The `behavioral-change-flag` / `behavioral-change-cleared` gate — your self-review plus the human merge cover it.
- Team-wide `introspect` / `introspection-done` between items — replaced by introspect-lite.
- `testability-concern`, `worktree-released`, `worktree-returned` — one owner per worktree, no sharing.

## Stays in force

- All hooks: the direct-bus-write block, the AskUserQuestion identity check, the rm-glob guard.
- `hello`, `bye`, `ping`/`pong`, `status`, `question`/`answer`, `refused`, `ack`, `nudge`; the bounded `pause`/`resume`/`escalate` directives.
- Liveness + idle machinery: `wake`, `i_am_truly_idle`, the gated `declare_idle`, activity logging.
- Token discipline and its injects; learnings injects; compaction-restore machinery.
- The AFK protocol — and M starts no new kickoff or pool refresh while the human is AFK.
- Team-scoping conventions: branch prefixes, PR title prefixes, commit trailers.
- Helper scripts run from the MAIN checkout root, never a worktree cwd.

## M's dual duty

M works its own item like any owner, but management preempts, always:

- Relay questions: answer within authority, otherwise `AskUserQuestion`; route answers back on the bus.
- Premise failures: close or replace the item, dispatch a replacement from the pool.
- Refusals: reassign, or return the dispatch with the verbatim human override.
- Reassign on every `pr-created`: update `ahod.assignments`, dispatch the next pool item to the freed owner.
- Route bridge events (`pr-comment`, `pr-review`, `ci-check`) for an AHOD item to the item's OWNER by exact agent ID. On `pr-state: merged`: tear down the worktree, flip the story status, mirror the project tracker if one is defined.
- File backlog items from peer `backlog-suggest` findings.
- Pool empty while PRs are open → freed owners handle merge fallout or go idle via the standard idle machinery. A pool refresh is a mini-kickoff (pool + foundations + stubs) with the human. The mode stays `ahod` until the human revokes it.

## Stand-down

On `/ahod-off`: M walks the in-flight assignments with the human — each item either finishes to PR (the owner completes the owner lifecycle) or parks (the owner commits WIP to the feat branch, adds a `## Handoff` note to the story file, emits a final `status`). Then M sets `mode` to `default`, removes the `ahod` key, and broadcasts `ahod-stand-down` (`{reason, wind_down}`). Normal relay resumes; a parked item later re-enters the default pipeline as an ordinary `story-created` to `senior-developer-*`. Items still finishing to PR after the flip complete their solo lifecycle; a `code-review-request` that routes to PP after the flip is an extra safety pass, not a relay resumption.
