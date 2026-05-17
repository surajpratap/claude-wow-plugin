# `<NEXT-from>` → `<NEXT-to>`

Slack-bridge OAuth-scope startup preflight (Story 095, sprint
2026-05-17-slack-bridge-hardening). **ADDED**
`plugin/bridge/slack/src/bridge/required-scopes.ts` — `REQUIRED_SCOPES` (the
authoritative required bot-token scope set) + pure `assertScopes` /
`normalizeGrantedScopes` / `missingScopesExitLine` helpers. **MODIFIED**
`plugin/bridge/slack/src/index.ts` — after the story-092 workspace guard the bridge
preflights the bot token's granted OAuth scopes (from `auth.test`'s
`response_metadata.scopes`, the SDK-surfaced `x-oauth-scopes` header) against
`REQUIRED_SCOPES`; any missing scope ⇒ fail-closed exit with a stable
`missing OAuth scope(s): <list>` stdout line, before handlers / HTTP / Socket Mode
start. An absent/empty scope list skips the preflight (never false-positive-bricks a
valid token). Also retrofits a flush-safe exit (`failClosedExit`) to BOTH the new
preflight exit and the merged story-092 workspace-guard exit (FINDING-22).
**MODIFIED** `plugin/bridge/slack/README.md` — the "Required bot-token scopes" table
gains `app_mentions:read` (the bridge subscribes to the `app_mention` event).
**ADDED** `plugin/tests/slack-required-scopes-sync.sh` — mechanical gate asserting the
README scope table equals `REQUIRED_SCOPES`. Bundled bash test-suite count 79 → 80.
**Consumer action after upgrade:** `claude plugin update claude-wow`, `/reload-plugins`,
restart peers. Just update `.version`.
