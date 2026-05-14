import type { WebClient } from '@slack/web-api';
import type { FeedWriter } from './feed-writer.js';
import type { SlackResolver } from './cache.js';

// Slack Block Kit blocks — we don't narrow the type here; callers pass the
// exact object shape Slack expects and we forward unchanged.
type BlocksArg = unknown[] | undefined;

// Wraps the Slack WebClient with a consistent shape + echoes every action
// into the event feed so S sees its own past behavior in the same timeline
// as inbound events.
export class SlackOps {
  constructor(
    private client: WebClient,
    private feed: FeedWriter,
    private resolver: SlackResolver,
    private botUserId: string,
  ) {}

  get botId(): string {
    return this.botUserId;
  }

  async send(args: {
    channel: string;
    text?: string;
    blocks?: BlocksArg;
    threadTs?: string;
  }): Promise<{ ts: string | null; channel: string | null }> {
    const resp = await this.client.chat.postMessage({
      channel: args.channel,
      text: args.text ?? '',
      blocks: args.blocks as never,
      thread_ts: args.threadTs,
    });
    if (resp.ok && resp.ts) {
      const channel = await this.resolver.channel(args.channel);
      await this.feed.append({
        kind: 'bot_sent',
        receivedAt: new Date().toISOString(),
        ts: resp.ts,
        channelId: args.channel,
        channelName: channel?.name ?? null,
        channelType: channel?.type ?? null,
        threadTs: args.threadTs ?? null,
        isThreadReply: Boolean(args.threadTs),
        userId: this.botUserId,
        isBot: true,
        text: args.text ?? '',
        blocks: args.blocks ?? null,
      });
    }
    return { ts: resp.ts ?? null, channel: resp.channel ?? null };
  }

  async edit(args: {
    channel: string;
    ts: string;
    text?: string;
    blocks?: BlocksArg;
  }): Promise<{ ok: boolean }> {
    const resp = await this.client.chat.update({
      channel: args.channel,
      ts: args.ts,
      text: args.text ?? '',
      blocks: args.blocks as never,
    });
    if (resp.ok) {
      const channel = await this.resolver.channel(args.channel);
      await this.feed.append({
        kind: 'bot_edited',
        receivedAt: new Date().toISOString(),
        ts: args.ts,
        channelId: args.channel,
        channelName: channel?.name ?? null,
        channelType: channel?.type ?? null,
        userId: this.botUserId,
        isBot: true,
        text: args.text ?? '',
        blocks: args.blocks ?? null,
      });
    }
    return { ok: Boolean(resp.ok) };
  }

  async remove(args: { channel: string; ts: string }): Promise<{ ok: boolean }> {
    const resp = await this.client.chat.delete({
      channel: args.channel,
      ts: args.ts,
    });
    if (resp.ok) {
      const channel = await this.resolver.channel(args.channel);
      await this.feed.append({
        kind: 'bot_deleted',
        receivedAt: new Date().toISOString(),
        ts: args.ts,
        channelId: args.channel,
        channelName: channel?.name ?? null,
        channelType: channel?.type ?? null,
        userId: this.botUserId,
        isBot: true,
      });
    }
    return { ok: Boolean(resp.ok) };
  }

  async addReaction(args: {
    channel: string;
    ts: string;
    name: string;
  }): Promise<{ ok: boolean }> {
    const resp = await this.client.reactions.add({
      channel: args.channel,
      timestamp: args.ts,
      name: args.name,
    });
    if (resp.ok) {
      await this.feed.append({
        kind: 'bot_reaction_added',
        receivedAt: new Date().toISOString(),
        ts: args.ts,
        channelId: args.channel,
        userId: this.botUserId,
        isBot: true,
        reactionName: args.name,
      });
    }
    return { ok: Boolean(resp.ok) };
  }

  async removeReaction(args: {
    channel: string;
    ts: string;
    name: string;
  }): Promise<{ ok: boolean }> {
    const resp = await this.client.reactions.remove({
      channel: args.channel,
      timestamp: args.ts,
      name: args.name,
    });
    if (resp.ok) {
      await this.feed.append({
        kind: 'bot_reaction_removed',
        receivedAt: new Date().toISOString(),
        ts: args.ts,
        channelId: args.channel,
        userId: this.botUserId,
        isBot: true,
        reactionName: args.name,
      });
    }
    return { ok: Boolean(resp.ok) };
  }

  async thread(args: {
    channel: string;
    ts: string;
  }): Promise<{ messages: unknown[] }> {
    const resp = await this.client.conversations.replies({
      channel: args.channel,
      ts: args.ts,
      limit: 200,
    });
    return { messages: resp.messages ?? [] };
  }

  async conversations(): Promise<{ channels: unknown[] }> {
    const resp = await this.client.users.conversations({
      types: 'public_channel,private_channel,im,mpim',
      limit: 200,
    });
    return { channels: resp.channels ?? [] };
  }
}
