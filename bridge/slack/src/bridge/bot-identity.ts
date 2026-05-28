import type { WebClient } from '@slack/web-api';

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- Slack event payloads are a mosaic of subtypes; we inspect at runtime.
type AnyEvent = any;

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- auth.test response shape varies across @slack/web-api versions.
type AuthTestResponse = any;

export interface BotIdentity {
  userId: string;
  botId: string;
  authResp: AuthTestResponse;
}

// captureBotIdentity — single source of truth for the bridge's own
// {userId, botId, authResp}. Called once at startup; cached in process
// memory. Throws on missing user_id (caller fail-closed-exits with the
// `[claude-slack-bridge] auth.test failed: <msg> — exiting` shape).
// `botId` comes from the `bot_id` field on auth.test responses; if
// absent we fall back to the empty string. KNOWN GAP: with botId='',
// predicate 2 (`bot_message` subtype matching) is short-circuited by
// the `botId &&` guard — and Slack typically omits `event.user` on
// bot_message events, so predicate 1 (`event.user === userId`) also
// won't fire. A bot_message event with no upstream botId in identity
// will pass through unfiltered. In practice, modern @slack/web-api
// versions always return `bot_id` from `auth.test`, so this gap is a
// defensive fallback only.
export async function captureBotIdentity(client: WebClient): Promise<BotIdentity> {
  const authResp: AuthTestResponse = await client.auth.test();
  const userId: string | undefined = authResp?.user_id;
  if (!userId) {
    throw new Error('auth.test returned no user_id');
  }
  const botId: string = authResp?.bot_id ?? '';
  return { userId, botId, authResp };
}

// eventIsFromOwnBot — per-event predicate, pure-local. Returns true if
// the event was emitted by our bridge's own bot user; false otherwise.
// Four predicates cover the inbound event shapes that can carry an
// own-bot author:
//   1. event.user === userId         (regular message, app_mention, reaction_*)
//   2. subtype=bot_message + bot_id  (bot_message subtype; event.user may be absent)
//   3. subtype=message_changed       (our bot edited its own message)
//   4. subtype=message_deleted       (our bot deleted its own message)
export function eventIsFromOwnBot(event: AnyEvent, identity: BotIdentity): boolean {
  if (!event) return false;
  const { userId, botId } = identity;

  if (event.user === userId) return true;

  if (event.subtype === 'bot_message' && botId && event.bot_id === botId) {
    return true;
  }

  if (event.subtype === 'message_changed' && event.message?.user === userId) {
    return true;
  }

  if (event.subtype === 'message_deleted' && event.previous_message?.user === userId) {
    return true;
  }

  return false;
}
