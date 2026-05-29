# Sprint retro doctrine

Project-agnostic protocol for sprint retros. M-only writes (standing-authority workflow-artifact pattern). Peers read this file at startup AND on every `read-retro-doctrine` broadcast — auto-injected by the MCP server `bus_emit` handler whenever any caller emits `review-closed` or `retro-open`.

## Trigger condition

M emits `retro-open` (to: `*`) when ALL of:

1. Every sprint manifest item has terminal status (`merged` / `shipped` / `parked` / `rejected`).
2. Every active reviewer has emitted `review-closed` for this `sprint_id`. The expected-reviewers set is configurable per sprint; the default is PP only.

**Stamp `last_all_terminal_ts`** when the LAST item transitions to terminal status. Anchors the fallback countdown.

**Fallback (5 min).** If condition 1 holds but condition 2 has not been satisfied within 5 minutes of `last_all_terminal_ts`, M emits `retro-open` anyway with a parallel `status` to `*` naming which reviewers' `review-closed` was missing. Tracker field `reviewers_closed: [<role>...]` (auto-init `[]` on sprint kickoff) is updated as `review-closed` arrives; the fallback compares its length against the expected-reviewer list.

**Idempotency.** Once `retro-open` has fired for a sprint (normal or fallback), M does not re-emit on subsequent `review-closed` arrivals. Track via `retro_open_fired: bool` in the offset tracker (auto-init `false`); set to `true` on emit; check before any future re-emit.

`retro-open` payload references the manifest path + summary stats (X shipped / Y parked / Z rejected; sprint duration; PR URLs).

## Multi-party flow

**Step 1 — Opening round.** Each peer (SD, PP, T, S if present, plus any future roles) emits `retro-opening` (to: `*`) covering:
- What went well from their POV.
- What didn't go well.
- Suggestions for OTHER peers (cross-feedback explicitly invited).

**Step 2 — Open discussion.** Peers reply to each other freely:
- `to: <peer-id>` for direct address.
- `to: *` for broadcast.
- Reply chains may disagree, push back, propose alternatives.

**Step 3 — M moderation.**
- M observes the bus throughout.
- May interject (`to: *`) to redirect when discussion stalls or repeats: e.g., "PP and SD have circled this point twice — can we move to action items?"
- Direct-pings any silent peer (`to: <peer-id>` `nudge`) after ~5 min of no input from them.
- Soft cap ~30 messages or ~30 min; M extends if productive, closes if not.

**Step 4 — `retro-close`.** M emits when discussion is done. Peers stop replying to retro threads.

**Step 5 — M synthesizes `retro.md`** at `implementations/sprints/<sprint-id>/retro.md` with these sections:
- `## Sprint outcomes` — what shipped, parked, rejected, with PR URLs.
- `## What worked` — themes M extracted from the discussion.
- `## What didn't` — themes M extracted.
- `## Cross-agent feedback` — specific advice peers gave each other (preserve attribution).
- `## Action items` — concrete next steps with owner role tagged.

## Etiquette

Every retro message, from any peer or M: disagree on ideas, never on the person. Frame feedback as observation + suggestion ("I noticed X happened — could we try Y?"), not "you should have done Y." Heated is fine; respectful is non-negotiable.

## Learnings-refresh window

Sprint-end is the natural reflection moment; piggyback a learnings-staleness sweep on it.

1. M emits a one-time `retro-learnings-window-open` (to: `*`) after `retro.md` synthesis is committed: payload `{sprint_id, deadline_ts: <now + 2 min>}`.
2. M emits a one-time `nudge` (to: `*`) with `payload: {repair: "consolidate-memory"}` at the start of the window — each peer's `nudge` handler routes the `repair` kind to invoke `bash "$(wow-locate scripts/consolidate-memory.sh)" <role>`, parses the stdout summary, and emits `learnings-consolidated` to `manager-*`. The nudge is broadcast so every peer gets a chance; per-role attribution inside the script picks up only the entries that role can claim.
3. Each peer (PP, SD, T, S) skims `implementations/learnings/<role>.md` for stale facts: outdated suite counts, version refs, deprecated conventions, removed bus message types. Edits inline if any found.
4. After the skim, peer emits `learnings-updated` to `manager-*` with payload `{path, sha_before, sha_after, summary}`. If nothing stale, peer emits NOTHING (no-op is graceful — peers may legitimately have nothing to update).
5. M waits 2 minutes after the window opens, then aggregates: count per peer (`{pp: 1, sd: 0, t: 2, s: 0}`) → folds into the retro digest as a "Learnings refresh" line. M also aggregates `learnings-consolidated` payload counts → folds `{total entries_added, total triage_count}` into the digest as a "Memory consolidation" line.
6. The window is advisory; M does NOT block sprint close on missing emits.

## Action items to backlog

For each action item synthesized into `retro.md` `## Action items`, M files a fresh `implementations/backlog/NNN-<slug>.md` with:

- `<!-- status: accepted -->` (or `<!-- status: triage -->` if M needs human input on framing).
- `<!-- concern: ... -->` and `<!-- size: ... -->` markers (M's best inference; flag for human triage if unsure).
- `<!-- source: sprint-<id>-retro -->` for provenance.

Surfaces in the human's next backlog query as part of the normal accepted-item pool.

## External-reviewer version-bump false-positive recurrence check

For sprint retros only: survey this sprint's PP plan-review threads. If an
external second-opinion reviewer flagged `<NEXT-from>` / `<NEXT-to>`
placeholders as a missing version bump anywhere, file a backlog item — the
external-reviewer-arming preface in `commands/pair-programmer.md`
("Plan-review version-literal check" point 4) may need re-strengthening or a
more mechanical intervention (`migration-entries-marker-check.sh` is the
planned successor mechanical test). The marker convention is in
`commands/_agent-protocol.md` → Sprint-mode version placeholder convention.

## Sprint manifest status flip

After `retro.md` is committed AND all action-item backlog files are filed, M flips the sprint manifest's top-level `status` to `complete`. The sprint directory is preserved (audit trail) — never deleted. The manifest's `status: complete` is the formal end-of-sprint signal; subsequent sprints reference it for cross-sprint analysis.
