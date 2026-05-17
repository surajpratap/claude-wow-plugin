# Slack bridge — Slack-app setup

The `claude-wow` Slack bridge connects the workflow to one Slack workspace over
**Socket Mode**. Slacker (`/slacker`) auto-launches it — you do not run it directly.
This document lists the Slack-app configuration the bridge requires; set it once when
you create the Slack app.

## Tokens

The bridge needs two tokens. Slacker reads them from
`~/.wow-<user>/slack/<project-key>/creds.json` (see `commands/slacker.md` → "Cred
shape") and passes them to the bridge process as environment variables:

| Env var | Token | Used for |
|---|---|---|
| `SLACK_BOT_TOKEN` | Bot token (`xoxb-…`) | every Slack Web API call |
| `SLACK_APP_TOKEN` | App-level token (`xapp-…`) | the Socket Mode connection |

## App-level token scope

The app-level token (`xapp-`) needs exactly one scope:

- `connections:write` — open the Socket Mode connection.

## Required bot-token scopes

Grant every scope below on the bot token (`xoxb-`). A missing scope fails the bridge
either at connect or silently mid-run, so treat the whole set as mandatory.

| Scope | Needed for |
|---|---|
| `chat:write` | `chat.postMessage`, `chat.update`, `chat.delete` — send / edit / delete messages |
| `reactions:read` | the `reaction_added` / `reaction_removed` events |
| `reactions:write` | `reactions.add`, `reactions.remove` |
| `users:read` | `users.info` — resolve a user id to a name |
| `channels:read` | `conversations.info` / `conversations.list` for public channels |
| `groups:read` | `conversations.info` / `conversations.list` for private channels |
| `im:read` | `users.conversations` enumerates direct messages (the `/conversations` endpoint) |
| `mpim:read` | `users.conversations` enumerates multi-person DMs (the `/conversations` endpoint) |
| `channels:history` | read public-channel messages — the `message.channels` events and `conversations.replies` |

> **Note on `mpim:read`.** As of story 090, by-name channel resolution
> (`channelByName`, `src/bridge/cache.ts`) no longer enumerates multi-person DMs, so
> `mpim:read` is **not** needed for that path. It stays required because
> `users.conversations` (`src/bridge/slack-ops.ts`, behind the bridge's
> `/conversations` HTTP endpoint) still enumerates `im,mpim`. A future audit may drop
> `mpim:read` if the `/conversations` enumeration is narrowed — until then, grant it.

## Optional bot-token scopes

Grant these only if the bot operates in the matching conversation type. Each pairs
with the Event Subscription of the same name in the table below.

| Scope | Grant when | Enables |
|---|---|---|
| `groups:history` | the bot works in private channels | reading private-channel messages (`message.groups`) |
| `im:history` | the bot handles direct messages | reading DM messages (`message.im`) |
| `mpim:history` | the bot handles multi-person DMs | reading multi-person-DM messages (`message.mpim`) |

## Event Subscriptions

Subscribe the Slack app to these bot events:

| Event | Required? |
|---|---|
| `app_mention` | required |
| `message.channels` | required — public-channel messages |
| `reaction_added` | required |
| `reaction_removed` | required |
| `message.groups` | only with the optional `groups:history` scope (private channels) |
| `message.im` | only with the optional `im:history` scope (direct messages) |
| `message.mpim` | only with the optional `mpim:history` scope (multi-person DMs) |

## Web API methods called (traceability)

For audit — every Slack Web API method the bridge calls, verified against
`bridge/slack/src/` on 2026-05-17:

| Method | Source file |
|---|---|
| `auth.test` | `src/index.ts` |
| `chat.postMessage` | `src/bridge/slack-ops.ts` |
| `chat.update` | `src/bridge/slack-ops.ts` |
| `chat.delete` | `src/bridge/slack-ops.ts` |
| `reactions.add` | `src/bridge/slack-ops.ts` |
| `reactions.remove` | `src/bridge/slack-ops.ts` |
| `conversations.replies` | `src/bridge/slack-ops.ts` |
| `users.conversations` | `src/bridge/slack-ops.ts` |
| `users.info` | `src/bridge/cache.ts` |
| `conversations.info` | `src/bridge/cache.ts` |
| `conversations.list` | `src/bridge/cache.ts` |

`auth.test` needs no scope (it works with any valid token) — it is listed here for
completeness only.
