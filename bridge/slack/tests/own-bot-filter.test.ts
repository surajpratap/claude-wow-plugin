// own-bot-filter.test.ts — unit cases for eventIsFromOwnBot + captureBotIdentity.
//
// Runs via `node --test --import tsx tests/own-bot-filter.test.ts`.
// Pure-local predicate truth table; no Slack-client network calls.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { captureBotIdentity, eventIsFromOwnBot, type BotIdentity } from '../src/bridge/bot-identity.js';

const identity: BotIdentity = {
  userId: 'U_OWN_BOT',
  botId: 'B_OWN_BOT',
  authResp: { ok: true, user_id: 'U_OWN_BOT', bot_id: 'B_OWN_BOT', team_id: 'T_X' },
};

test('eventIsFromOwnBot: regular message from our bot → true', () => {
  assert.equal(eventIsFromOwnBot({ user: 'U_OWN_BOT', text: 'hi' }, identity), true);
});

test('eventIsFromOwnBot: regular message from another user → false', () => {
  assert.equal(eventIsFromOwnBot({ user: 'U_SOMEONE', text: 'hi' }, identity), false);
});

test('eventIsFromOwnBot: bot_message subtype with matching bot_id → true', () => {
  assert.equal(
    eventIsFromOwnBot({ subtype: 'bot_message', bot_id: 'B_OWN_BOT', bot_profile: {} }, identity),
    true,
  );
});

test('eventIsFromOwnBot: bot_message subtype with different bot_id → false', () => {
  assert.equal(
    eventIsFromOwnBot({ subtype: 'bot_message', bot_id: 'B_OTHER_BOT' }, identity),
    false,
  );
});

test('eventIsFromOwnBot: message_changed where event.message.user is us → true', () => {
  assert.equal(
    eventIsFromOwnBot(
      { subtype: 'message_changed', message: { user: 'U_OWN_BOT', text: 'edit' } },
      identity,
    ),
    true,
  );
});

test('eventIsFromOwnBot: message_changed where event.message.user is someone else → false', () => {
  assert.equal(
    eventIsFromOwnBot(
      { subtype: 'message_changed', message: { user: 'U_SOMEONE', text: 'edit' } },
      identity,
    ),
    false,
  );
});

test('eventIsFromOwnBot: message_deleted where previous_message.user is us → true', () => {
  assert.equal(
    eventIsFromOwnBot(
      { subtype: 'message_deleted', previous_message: { user: 'U_OWN_BOT' } },
      identity,
    ),
    true,
  );
});

test('eventIsFromOwnBot: message_deleted where previous_message.user is someone else → false', () => {
  assert.equal(
    eventIsFromOwnBot(
      { subtype: 'message_deleted', previous_message: { user: 'U_SOMEONE' } },
      identity,
    ),
    false,
  );
});

test('eventIsFromOwnBot: reaction with event.user === us → true', () => {
  assert.equal(eventIsFromOwnBot({ user: 'U_OWN_BOT', reaction: 'thumbsup' }, identity), true);
});

test('eventIsFromOwnBot: undefined event → false (defensive)', () => {
  assert.equal(eventIsFromOwnBot(undefined as unknown as { user: string }, identity), false);
});

test('eventIsFromOwnBot: bot_message with empty botId in identity → false (no match)', () => {
  const emptyBotIdIdentity: BotIdentity = { ...identity, botId: '' };
  assert.equal(
    eventIsFromOwnBot({ subtype: 'bot_message', bot_id: 'B_SOMETHING' }, emptyBotIdIdentity),
    false,
  );
});

test('captureBotIdentity: happy path returns userId/botId/authResp', async () => {
  const mockClient = {
    auth: {
      test: async () => ({ ok: true, user_id: 'U_X', bot_id: 'B_X', team_id: 'T_X' }),
    },
  } as unknown as Parameters<typeof captureBotIdentity>[0];
  const identity = await captureBotIdentity(mockClient);
  assert.equal(identity.userId, 'U_X');
  assert.equal(identity.botId, 'B_X');
  assert.equal(identity.authResp?.team_id, 'T_X');
});

test('captureBotIdentity: missing user_id throws', async () => {
  const mockClient = {
    auth: { test: async () => ({ ok: true }) },
  } as unknown as Parameters<typeof captureBotIdentity>[0];
  await assert.rejects(captureBotIdentity(mockClient), /no user_id/);
});

test('captureBotIdentity: missing bot_id falls back to empty string (does not throw)', async () => {
  const mockClient = {
    auth: { test: async () => ({ ok: true, user_id: 'U_Y' }) },
  } as unknown as Parameters<typeof captureBotIdentity>[0];
  const identity = await captureBotIdentity(mockClient);
  assert.equal(identity.userId, 'U_Y');
  assert.equal(identity.botId, '');
});
