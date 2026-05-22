# `<NEXT-from>` → `<NEXT-to>`

<!-- sprint-mode placeholder: <NEXT-from> + <NEXT-to> are substituted by sprint-merge-bump.sh -->

## Added

- **`plugin/tests/fixtures/golden/`** — real captured producer samples (each with a `_provenance` key): `pr-created.json` (has `base`, not `pr_base`), `manifest-item.json` (`id`+`story` path, no `story_id`), `bus-message.json` (the server's REAL `in_reply_to:{ts}` wrap — captured by invoking `bus_emit`, NOT the input-schema's mis-stated `{ts,from}`). Plus `golden/bad/` wrong-shape fixtures (FINDING-36 `pr_base` / FINDING-37 `story_id` / FINDING-32 flat `in_reply_to`) used as committed red-green cases.
- **`plugin/tests/lib/contract-golden.sh`** — sourceable `assert_fixture_matches_golden <golden> <fixture> [<required-keys>]`. Compares a RECURSIVE shape signature (`<dotted-path>:<json-type>`, `_provenance` excluded), so it catches nested/flat `in_reply_to`, `payload` string-vs-object, and array-vs-string mismatches — not just top-level keys. Fails on a fixture path absent from the golden, a type mismatch, or a missing required key.
- **`plugin/tests/contract-golden-freshness.sh`** — anti-drift guard: invokes the real `bus_emit` in a TEMP project (never the repo bus) and diffs shape vs golden; diffs a real in-repo manifest item; doc-anchors the pr-created `base` key against `_agent-protocol.md`; and asserts the helper FAILS on the committed `bad/` fixtures (red-green).

## Modified

- **`plugin/tests/{mcp-server-sprint-code-review-suppress,manager-pace-status-unstarted-dispatched,mcp-server-bus-emit-output-shape}.sh`** — each now sources the lib + calls `assert_fixture_matches_golden` against its contract fixture (reference adoption; behavior otherwise unchanged).
- **`plugin/commands/pair-programmer.md`** — one-line review pointer: contract-boundary fixtures validate against the golden set via the helper.

## Why

The prior sprint's headline retro lesson, mechanized. The emitted-but-inert / fixture-masking class hit 3× (FINDING-36/37 + the 138 consumer gap) because a contract test's hand-built fixture — authored by the same person as the buggy consumer — encoded the same wrong shape, passing green while production was inert. Golden-from-real-producer + a recursive shape-diff helper + an anti-drift freshness guard make a wrong-shaped fixture FAIL the suite, with no reliance on a reviewer remembering to check. (The mechanism proved itself: capturing the real `bus_emit` immediately surfaced the `in_reply_to:{ts}` shape the story's own AC had mis-stated as `{ts,from}`.)

## Consumer action

`/reload-plugins` + restart peers per standard upgrade hygiene. New contract tests should validate fixtures against `plugin/tests/fixtures/golden/` via `assert_fixture_matches_golden`.

## Closes

Backlog item 175 (sprint 2026-05-22-self-correction-2). Predecessors: 134 (bus-emit output-shape test — the invoke-real-producer technique), 137 (3-corner producer assertion), 138 (manifest-item shape).
