# `<NEXT-from>` → `<NEXT-to>`

<!-- sprint-mode placeholder: <NEXT-from> + <NEXT-to> are substituted by sprint-merge-bump.sh -->

## Added

- **`plugin/scripts/merge-authority-parse.sh`** — a SECURITY-CRITICAL, fail-CLOSED recognizer for a human merge-authority grant. Detects a CANDIDATE only (never decides authority) + extracts a candidate scope (`this-sprint` / `per-item` / `final-integration` / `unscoped`). Rejects (exit 1) any ambiguous phrasing — negation ("M can't merge"), question ("can M merge?"), conditional ("once tests pass…"), third-party ("he can merge"), non-grant text. POSIX ERE only (BSD/macOS-safe).
- **`plugin/tests/merge-authority-parse.sh`** — 28-case battery: real last-sprint grant phrases → correct scope; the full security-negative set → never a candidate.
- Two bus message types **`merge-authority-grant`** + **`merge-authority-ack`** added to `server.py` `ALLOWED_TYPES` (so the emits are not rejected — the feature is not inert) and to the `_agent-protocol.md` message-types table.

## Modified

- **`plugin/commands/slacker.md`** — S runs the parser on inbound human Slack messages; on a candidate, relays a STRUCTURED `merge-authority-grant` to M (not a free-text interpretation).
- **`plugin/commands/manager.md`** — M's grant-handling: a `merge_authority` state machine in the sprint manifest (`pending` on candidate → `active` ONLY on explicit human confirm → `revoked`). M's `merge-authority-ack` ALWAYS asks the human to confirm scope; M exercises merge authority ONLY while `active` and within the granted scope.

## Why

Last sprint the human granted M merge authority via free-text Slack; S had to interpret it and M recorded the scope by hand — interpretation in the loop for a high-consequence authority. This makes the grant a parseable candidate + a structured, auditable ack, with a **fail-SAFE-by-construction** design: the parser cannot grant; authority goes active only on the human's explicit confirm. Every false-positive phrasing degrades to "nothing happens" or "M asks to confirm", never "M merges".

## Consumer action

`/reload-plugins` + restart peers per standard upgrade hygiene. The standing default remains human-merges unless the human grants (and confirms) a scoped merge authority.

## Closes

Backlog item 179 (sprint 2026-05-22-self-correction-2). Relates to backlog 172 (short relays). Predecessor: the auto-merge-revoked / human-merges default.
