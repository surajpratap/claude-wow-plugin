import type { WebClient } from '@slack/web-api';

const DEFAULT_TTL_MS = 60 * 60 * 1000; // 1 hour

interface CacheEntry<T> {
  value: T;
  expiresAt: number;
}

class TTLCache<K, V> {
  private store = new Map<K, CacheEntry<V>>();

  constructor(private ttlMs: number = DEFAULT_TTL_MS) {}

  get(key: K): V | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (Date.now() > entry.expiresAt) {
      this.store.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key: K, value: V): void {
    this.store.set(key, { value, expiresAt: Date.now() + this.ttlMs });
  }
}

export interface UserInfo {
  id: string;
  name: string;
  realName: string;
  isBot: boolean;
  timezone: string | null;
}

export interface ChannelInfo {
  id: string;
  name: string;
  type: 'public' | 'private' | 'im' | 'mpim' | 'unknown';
  topic: string;
  isMember: boolean;
}

export class SlackResolver {
  private userCache = new TTLCache<string, UserInfo>();
  private channelCache = new TTLCache<string, ChannelInfo>();

  constructor(private client: WebClient) {}

  async user(userId: string): Promise<UserInfo | null> {
    const cached = this.userCache.get(userId);
    if (cached) return cached;

    try {
      const resp = await this.client.users.info({ user: userId });
      if (!resp.user || !resp.user.id) return null;
      const info: UserInfo = {
        id: resp.user.id,
        name: resp.user.name ?? resp.user.id,
        realName: resp.user.real_name ?? resp.user.name ?? resp.user.id,
        isBot: Boolean(resp.user.is_bot),
        timezone: resp.user.tz ?? null,
      };
      this.userCache.set(userId, info);
      return info;
    } catch (err) {
      console.error('[resolver] user lookup failed for', userId, err);
      return null;
    }
  }

  async channel(channelId: string): Promise<ChannelInfo | null> {
    const cached = this.channelCache.get(channelId);
    if (cached) return cached;

    try {
      const resp = await this.client.conversations.info({ channel: channelId });
      const ch = resp.channel;
      const id = ch?.id;
      if (!ch || !id) return null;
      let type: ChannelInfo['type'] = 'unknown';
      if (ch.is_im) type = 'im';
      else if (ch.is_mpim) type = 'mpim';
      else if (ch.is_private) type = 'private';
      else if (ch.is_channel) type = 'public';
      const info: ChannelInfo = {
        id,
        name: ch.name ?? id,
        type,
        topic: ch.topic?.value ?? '',
        isMember: Boolean(ch.is_member),
      };
      this.channelCache.set(channelId, info);
      return info;
    } catch (err) {
      console.error('[resolver] channel lookup failed for', channelId, err);
      return null;
    }
  }

  // Resolve a channel *by name* (minus any leading `#`). Paginates through
  // conversations.list since Slack has no direct "get-by-name" endpoint.
  // Only used on bridge startup to resolve BRIDGE_CHANNEL — not a hot path —
  // so no dedicated name→id cache beyond the standard id→info cache the
  // caller seeds via channel().
  async channelByName(name: string): Promise<ChannelInfo | null> {
    const wanted = name.replace(/^#/, '').toLowerCase();
    let cursor: string | undefined;
    try {
      do {
        const resp = await this.client.conversations.list({
          cursor,
          limit: 200,
          types: 'public_channel,private_channel,mpim',
          exclude_archived: true,
        });
        for (const ch of resp.channels ?? []) {
          if ((ch.name ?? '').toLowerCase() === wanted && ch.id) {
            // Seed the id→info cache so subsequent channel(id) hits are free.
            let type: ChannelInfo['type'] = 'unknown';
            if (ch.is_mpim) type = 'mpim';
            else if (ch.is_private) type = 'private';
            else if (ch.is_channel) type = 'public';
            const info: ChannelInfo = {
              id: ch.id,
              name: ch.name ?? ch.id,
              type,
              topic: ch.topic?.value ?? '',
              isMember: Boolean(ch.is_member),
            };
            this.channelCache.set(ch.id, info);
            return info;
          }
        }
        cursor = resp.response_metadata?.next_cursor || undefined;
      } while (cursor);
      return null;
    } catch (err) {
      console.error('[resolver] channelByName lookup failed for', name, err);
      return null;
    }
  }
}
