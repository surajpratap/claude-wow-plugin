# `<NEXT-from>` → `<NEXT-to>`

<!-- sprint-mode placeholder: <NEXT-from> + <NEXT-to> are substituted by sprint-merge-bump.sh -->

## Added

- **`plugin/scripts/plan-committed-check.sh`** + test — guard SD runs before `plan-done`: a plan file must be git-tracked, clean vs HEAD, AND on a `feat/*` branch (rejects `main` + detached HEAD). Prevents the orphaned-untracked-on-`main` plan.
- **`plugin/tests/plan-location-doctrine.sh`** — doctrine-regression grep pinning the worktree-rooted-plans contract across all 6 role files (so it can't silently revert).

## Modified (plan-location migration — plans live in the worktree on the feat branch)

- **`commands/_agent-protocol.md`** — new "Plan-ref resolution" section: plans live at `.worktrees/<NNN-slug>/implementations/plans/<NNN-slug>.md` on `feat/<NNN-slug>`; the bare bus `ref` is resolved by consumers as `.worktrees/<slug>/<ref>` (slug = ref basename), so it works for every plan-carrying message even though most lack a `worktree` field.
- **`commands/senior-developer.md`** — `story-created` drafts the plan INSIDE the worktree + `git add` (tracks from the start); claimed-check/catch-up + file-event self-check resolve the WORKTREE plan; `plan-done` runs `plan-committed-check.sh`.
- **`commands/_senior-developer-startup.md`** — startup catch-up checks the worktree plan (a restarted SD must not redraft/re-orphan).
- **`commands/pair-programmer.md`** — Working context resolves the worktree plan via slug-derive.
- **`commands/tester.md`** — Discover reads the plan from the worktree.
- **`commands/manager.md`** — finalize sweep no longer treats `implementations/plans/*.md` as a normal swept path (legacy/anomaly only — a plan on `main` is now surfaced, not silently swept).

## Why

SD drafted plans at `story-created` while still on `main`'s cwd (worktree entered only at `plan-approved`), so plans orphaned untracked on `main` (135/137/138/139). The fix moves WHERE plans live — into the worktree, tracked on the feat branch from the start — and updates every plan-path consumer (SD/PP/T/M) + the bus-ref locator contract so the migration isn't a half-migration.

## Consumer action

`/reload-plugins` + restart peers per standard upgrade hygiene. Plans now ride the feat branch; resolve a plan `ref` as `.worktrees/<slug>/<ref>`.

## Closes

Backlog 161 (sprint 2026-05-22-self-correction-2). Design spec: docs/superpowers/specs/2026-05-22-plan-location-migration-design.md.
