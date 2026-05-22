# `<NEXT-from>` → `<NEXT-to>`

<!-- sprint-mode placeholder: <NEXT-from> + <NEXT-to> are substituted by sprint-merge-bump.sh -->

## Added

- **`plugin/scripts/contract-size-recheck.sh`** — dispatch-time advisory size heuristic. Flags a story/backlog as NOT-tiny (exit 1) when its text touches >1 `commands/*.md` role file, a bus payload key/field, or an artifact location (move/relocate/orphan/where-X-lives/location-migration). POSIX ERE only (no `\b`; runs on stock BSD/macOS grep). Exit 0 = tiny-ok, 1 = ≥medium (reasons + "name the contract owner"), 2 = usage.
- **`plugin/tests/contract-size-recheck.sh`** — validates against the REAL in-repo corpus (story 140 + backlogs 159/161 → ≥medium; the terse story 138 → tiny, pinning the story-only limitation) plus inflection cases (relocate/relocated/relocation/orphaned) and a `remove`-must-not-fire word-boundary guard — NOT regex-shaped synthetic fixtures.

## Modified

- **`plugin/commands/manager.md`** — Per-item-dispatch step 0: M runs `contract-size-recheck.sh` on the story/backlog before dispatching a tiny/small item; a ≥medium signal prompts a sizing re-check + naming the contract owner (manifest `contract`, story 102). Advisory.

## Why

Stories 140 + 138 were specced "tiny" but were multi-role migrations with cross-role review surface (140 had to be parked mid-sprint). Contract-sizing (story 102) ran only at sprint-planning; a dispatch-time re-check catches mis-sized items before SD burns a plan cycle. Companion to story 141 (the producer side of the contract discipline).

## Known limitation

The heuristic reads the story/backlog TEXT, so a terse sprint story that defers its spec to a backlog/design (e.g. story 138) won't flag from the story alone — its backlog does. A plan-submit-time re-check (where the full cross-role surface is visible) is a noted follow-up.

## Consumer action

`/reload-plugins` + restart peers per standard upgrade hygiene. M's dispatch step now includes the advisory size re-check.

## Closes

Backlog item 176 (sprint 2026-05-22-self-correction-2). Predecessors: 102 (contract-sizing at sprint-planning + the manifest `contract` field), 141 (companion — producer side).
