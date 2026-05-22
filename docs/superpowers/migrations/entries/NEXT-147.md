# `<NEXT-from>` → `<NEXT-to>`

<!-- sprint-mode placeholder: <NEXT-from> + <NEXT-to> are substituted by sprint-merge-bump.sh -->

## Added

- **`plugin/scripts/plan-shape-gate.sh`** — diff-scoped auto-gate for `plan-shape-check.sh` (139's `## AC count` lint). Runs the lint on ONLY the plan files MODIFIED on the current branch (merge-base diff), so a missing section is caught automatically without anyone remembering. Diff-scoping sidesteps predating plans that lack the section (a blanket scan-all is non-viable). Hardened base-ref: `git fetch` (avoid stale-`origin/main` over-scope) → `origin/main` merge-base → local `main`/upstream → `HEAD~1` → clear no-op; `--diff-filter=AM` (skip deleted/renamed). Never false-fails in degenerate git states.
- **`plugin/tests/plan-shape-gate.sh`** — temp-git-repo fixtures: modified section-less plan fails; modified-with-section passes; a predating UNMODIFIED section-less plan is ignored (diff-scope); drafts exempt; multi-commit-no-remote branch still gated (local-main merge-base); deleted plan no false-fail.

## Modified

- **`plugin/tests/run-all.sh`** + **root `tests/run-all.sh`** — WIRE the gate to AUTO-RUN: a run-all step invokes `plan-shape-gate.sh` against the git-toplevel; a flagged modified plan fails run-all. (The WOW has no CI — run-all IS the auto-trigger; an unwired gate would be inert.)

## Why

Story 139's `plan-shape-check.sh` was prose-triggered (SD/PP doctrine pointers) — "relies on the agent remembering," the class this sprint targets. The diff-scoped gate wired into run-all is the strictly-mechanical form: it runs every verification on the branch's modified plans, no one having to invoke it.

## Consumer action

`/reload-plugins` + restart peers per standard upgrade hygiene. `run-all` now auto-gates the branch's modified plans for the `## AC count` section.

## Closes

Backlog 174 (sprint 2026-05-22-self-correction-2). Builds on story 139 (`plan-shape-check.sh`, v3.24.5).
