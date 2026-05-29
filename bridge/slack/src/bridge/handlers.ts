import type { App } from '@slack/bolt';
import type { FeedWriter } from './feed-writer.js';
import type { SlackResolver } from './cache.js';
import type { ChannelScope } from './http-server.js';
import { eventIsFromOwnBot, type BotIdentity } from './bot-identity.js';
import type { Interactors } from './interactors.js';

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- Slack event payloads are a mosaic of subtypes; we inspect at runtime.
type AnyEvent = any;

// Registers Bolt handlers that turn every inbound Slack event into a rich,
// normalized JSONL record on the event feed.
export function registerHandlers(args: {
  app: App;
  feed: FeedWriter;
  resolver: SlackResolver;
  identity: BotIdentity;
  scope: ChannelScope | null;
  interactors: Interactors | null;
}): void {
  const { app, feed, resolver, identity, scope, interactors } = args;
  const { userId: botUserId } = identity;

  // Lazily ensure the per-user record for inbound author IDs, swallowing any
  // unexpected error so an interactor-registry hiccup never blocks a feed
  // write. Returns null when interactors isn't wired (e.g., WOW_INTERACTORS_PATH
  // unset) or when userId is missing on the event.
  const enrichInteractor = async (userId: string | undefined | null) => {
    if (!interactors || !userId) return null;
    try {
      return await interactors.ensureInteractor(app.client, userId);
    } catch (err) {
      console.warn(`[bridge] interactor enrichment failed for ${userId}:`, err);
      return null;
    }
  };

  // When a scope is set, every inbound event must originate from the scoped
  // channel id. Mismatches are silently dropped — no feed write, no log —
  // so the bot behaves as if it wasn't in that channel at all. The S agent
  // relies on this as a defense-in-depth layer behind its learnings rule.
  const inScope = (channelId: string | undefined): boolean => {
    if (!scope) return true;
    return Boolean(channelId) && channelId === scope.id;
  };

  const isBotMentioned = (text: string | undefined): boolean => {
    if (!text) return false;
    return text.includes(`<@${botUserId}>`);
  };

  const enrichUser = async (userId: string | undefined) => {
    if (!userId) return { userId: null, userName: null, userRealName: null, isBot: null };
    const info = await resolver.user(userId);
    return {
      userId,
      userName: info?.name ?? null,
      userRealName: info?.realName ?? null,
      isBot: info?.isBot ?? null,
    };
  };

  const enrichChannel = async (channelId: string | undefined) => {
    if (!channelId) return { channelId: null, channelName: null, channelType: null };
    const info = await resolver.channel(channelId);
    return {
      channelId,
      channelName: info?.name ?? null,
      channelType: info?.type ?? null,
    };
  };

  // ─── app_mention ──────────────────────────────────────────────────────────
  app.event('app_mention', async ({ event }) => {
    const e = event as AnyEvent;
    if (eventIsFromOwnBot(e, identity)) return;
    if (!inScope(e.channel)) return;
    const channel = await enrichChannel(e.channel);
    const user = await enrichUser(e.user);
    const interactor = await enrichInteractor(e.user);
    await feed.append({
      kind: 'app_mention',
      receivedAt: new Date().toISOString(),
      ts: e.ts,
      ...channel,
      ...user,
      interactor,
      threadTs: e.thread_ts ?? null,
      isThreadReply: Boolean(e.thread_ts) && e.thread_ts !== e.ts,
      text: e.text ?? '',
      blocks: e.blocks ?? null,
      files: e.files ?? null,
      botMentioned: true,
      isDmToBot: false,
    });
  });

  // ─── message (catches new messages, edits, deletes, bot messages) ─────────
  app.message(async ({ message }) => {
    const e = message as AnyEvent;

    if (!inScope(e.channel)) return;

    // Suppress our own bot's outbound messages — we've already logged them as
    // `bot_sent` via the HTTP path. Covers regular bot-user messages, the
    // bot_message subtype (where `user` may be absent), and message_changed /
    // message_deleted shapes where the original-author field is inside
    // event.message / event.previous_message.
    if (eventIsFromOwnBot(e, identity)) return;

    // Normalize subtype → our kind.
    let kind = 'message';
    let previousText: string | null = null;
    let deletedText: string | null = null;
    let eventUserId: string | undefined;
    let eventTs: string | undefined;
    let eventText: string | undefined;

    if (e.subtype === 'message_changed') {
      kind = 'message_edited';
      previousText = e.previous_message?.text ?? null;
      eventUserId = e.message?.user;
      eventTs = e.message?.ts ?? e.ts;
      eventText = e.message?.text;
    } else if (e.subtype === 'message_deleted') {
      kind = 'message_deleted';
      deletedText = e.previous_message?.text ?? null;
      eventUserId = e.previous_message?.user;
      eventTs = e.previous_message?.ts ?? e.deleted_ts ?? e.ts;
      eventText = null as unknown as string | undefined;
    } else {
      eventUserId = e.user;
      eventTs = e.ts;
      eventText = e.text;
    }

    const channel = await enrichChannel(e.channel);
    const user = await enrichUser(eventUserId);
    const interactor = await enrichInteractor(eventUserId);
    const isDmToBot = channel.channelType === 'im';

    await feed.append({
      kind,
      receivedAt: new Date().toISOString(),
      ts: eventTs ?? null,
      ...channel,
      ...user,
      interactor,
      threadTs: e.thread_ts ?? e.message?.thread_ts ?? null,
      isThreadReply: Boolean(e.thread_ts ?? e.message?.thread_ts),
      text: eventText ?? null,
      blocks: e.blocks ?? e.message?.blocks ?? null,
      files: e.files ?? e.message?.files ?? null,
      botMentioned: isBotMentioned(eventText),
      isDmToBot,
      previousText,
      deletedText,
      subtype: e.subtype ?? null,
    });
  });

  // ─── reaction_added ───────────────────────────────────────────────────────
  app.event('reaction_added', async ({ event }) => {
    const e = event as AnyEvent;
    if (eventIsFromOwnBot(e, identity)) return; // we already wrote bot_reaction_added
    const channelId = e.item?.channel;
    if (!inScope(channelId)) return;
    const channel = await enrichChannel(channelId);
    const user = await enrichUser(e.user);
    const interactor = await enrichInteractor(e.user);
    await feed.append({
      kind: 'reaction_added',
      receivedAt: new Date().toISOString(),
      ts: e.item?.ts ?? null,
      ...channel,
      ...user,
      interactor,
      reactionName: e.reaction,
      itemType: e.item?.type ?? null,
    });
  });

  // ─── reaction_removed ─────────────────────────────────────────────────────
  app.event('reaction_removed', async ({ event }) => {
    const e = event as AnyEvent;
    if (eventIsFromOwnBot(e, identity)) return;
    const channelId = e.item?.channel;
    if (!inScope(channelId)) return;
    const channel = await enrichChannel(channelId);
    const user = await enrichUser(e.user);
    const interactor = await enrichInteractor(e.user);
    await feed.append({
      kind: 'reaction_removed',
      receivedAt: new Date().toISOString(),
      ts: e.item?.ts ?? null,
      ...channel,
      ...user,
      interactor,
      reactionName: e.reaction,
      itemType: e.item?.type ?? null,
    });
  });
}
