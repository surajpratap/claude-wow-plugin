# Token-conservation doctrine

This file is the canonical token-discipline doctrine for the WOW multi-agent workflow. M reads it once at startup, caches the full text, and pipes it inline as `payload.token_discipline_doctrine` on every `story-created`. Peers consume it as fresh context per-story-dispatch — bypasses the in-context-prompt-staleness problem.

Ownership: M-only writes (standing-authority workflow-artifact commits). All peers read on receipt of `story-created`.

---

## Why we conserve

Token cost is real. It scales with team size (5 roles × full session each) and with story breadth (large stories repeatedly re-read large directive files). Every wasted token in the orchestrator hits the user's wallet. Cheaper subagents (Haiku, Sonnet) can do well-defined procedural work at ~5× lower cost per token while preserving orchestrator quality on judgment-driven decisions. The discipline below is self-imposed — no metrics enforcer, no programmatic block. Compliance is a peer-review concern.

## The delegation rule

When you see well-defined work that doesn't require your full conversation context, you MUST spawn an `Agent` subagent on Haiku (or Sonnet for slightly more complex bounded work) rather than do it yourself in the main session. The orchestrator's job is to reason and decide; subagents do the heavy lifting.

## What's "well-defined"

A task is delegatable when ALL of the following hold:

- **Bounded inputs.** Specific file paths, specific patterns, specific commands — not "look around and report what you see."
- **Bounded outputs.** A list, a count, a yes/no, parsed JSON — not open-ended prose synthesis.
- **Independent of in-flight conversation context.** A subagent can succeed without knowing what the orchestrator just decided three turns ago.
- **Procedural rather than judgment-driven.** Pattern-matching, file-walking, command-running — not architectural calls.

## What's NOT delegatable

Keep these in the main session:

- **Architectural / design decisions.** Choosing between two approaches; weighing trade-offs.
- **Cross-file reasoning** that requires the orchestrator's full context (e.g., "is this consistent with what we decided in turn 7 about the bus protocol?").
- **Anything where the result feeds directly back into the role's running thread without a clean handoff point.** Subagents return a single response; the orchestrator can't ask follow-ups in the same nested turn.
- **Time-sensitive responses.** Subagent latency adds 1–3 min per round-trip. Don't delegate when the response needs to land in <30s.

## Project-side role catalogues

This file ships the discipline only — WHEN to delegate, what counts as well-defined, what to avoid. Concrete per-role delegation catalogues (the actual local work-shapes each role should delegate) are project-specific and live in `implementations/learnings/<role>.md`, empty on fresh install and accumulated by the team as it identifies bounded work worth delegating.

## Subagent invocation pattern

Every role spawns subagents via the `Agent` tool with this canonical shape:

```
Agent({
  description: "<3-5 word task description>",
  subagent_type: "Explore" | "general-purpose",
  model: "haiku" | "sonnet",
  prompt: "<self-contained task with: doctrine excerpt + inputs + expected output shape + length cap>"
})
```

Conventions:

- `subagent_type: Explore` — read-only searches, file discovery, grep audits.
- `subagent_type: general-purpose` — everything else (test runs, multi-step work).
- `model: haiku` — clearly procedural work (the default; use whenever in doubt).
- `model: sonnet` — slightly more complex bounded work where Haiku underperforms.
- `model: opus` — allowed for harder bounded work where Sonnet underperforms (rare; prefer the cheaper model when output quality is comparable).

Prompt body must include: a brief doctrine excerpt (so the subagent inherits the discipline), specific inputs, expected output shape, and a length cap (e.g., "report under 200 words"). Self-contained prompts produce focused responses; underspecified prompts produce sprawling ones.

## Recursive rule

Subagents also follow the doctrine. The orchestrator includes the doctrine excerpt in the subagent prompt body so deep-nested work also delegates appropriately. A Haiku subagent that needs to do its own bounded sub-work can spawn its own deeper subagents — the discipline propagates.

## Anti-patterns

Watch for these patterns that signal "this should have been delegated":

- **Re-reading huge files in the main session** when a subagent could grep the relevant part. If you're about to `Read` a 1000-line file to find one section, delegate the find to an Explore subagent.
- **Doing 5 sequential greps in the main session** when one Explore subagent could do all 5 in parallel and return a single consolidated result.
- **"Let me just check" patterns that aren't bounded** — these often expand into 10+ tool calls. If you can't predict the output shape before starting, you need to scope the task before delegating; don't do it inline.
- **Delegating work that genuinely needs the orchestrator's context.** Creates wasted round-trips when the subagent has to ask back or returns wrong-shape results. If the task has implicit context dependencies, do it in-session or spend a turn making the context explicit before delegating.
