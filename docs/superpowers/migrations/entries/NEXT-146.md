# `<NEXT-from>` → `<NEXT-to>`

<!-- sprint-mode placeholder: <NEXT-from> + <NEXT-to> are substituted by sprint-merge-bump.sh -->

## Modified

- **`plugin/tests/directive-files-atomic.sh`** — `check_no_residual_placeholders` no longer takes hardcoded line ranges. Allowed `<NEXT-*>` example regions are now detected via `NEXT-PLACEHOLDER-EXAMPLE-START/END` sentinel-comment pairs, parsed by a LINE-ORDERED state machine (nested START / END-without-START / EOF-while-open all fail; only balanced pairs form `(start,end)`-exclusive regions — so a `<NEXT-*>` on a marker line fails). Designated-files policy: only `senior-developer.md` / `pair-programmer.md` / `_agent-protocol.md` may carry markers; a marker or any `<NEXT-*>` in a non-designated file fails (preserves the prior empty-range semantics). A fixture matrix proves the edge cases.
- **`plugin/commands/senior-developer.md` / `pair-programmer.md` / `_agent-protocol.md`** — wrapped their deliberate `<NEXT-*>` example regions in the sentinel pairs (bracketing exactly the deliberate examples — narrower than the old line ranges, never wider).

## Why

The hardcoded line ranges (`senior-developer.md` 100-225, `pair-programmer.md` 185-208, `_agent-protocol.md` 905-942) drifted: every story editing those files above the range had to hand-bump the numbers (story 139 bumped two) and the ranges false-positived mid-cascade. Sentinel markers move with the content — no renumbering, no mid-cascade drift. Mirrors story 138's `UNSTARTED-DISPATCHED-RECIPE` sentinel-pair pattern.

## Consumer action

`/reload-plugins` + restart peers per standard upgrade hygiene. No behavior change for the leak detection (a `<NEXT-*>` outside a marked region still fails) — only HOW the allowed region is detected.

## Closes

Backlog 173 (sprint 2026-05-22-self-correction-2). Predecessors: 138 (sentinel-pair pattern), 139 (the line-range bump that motivated this).
