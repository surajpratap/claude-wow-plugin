import { existsSync, readFileSync } from 'node:fs';
import type { WebClient } from '@slack/web-api';

// Story 155 — meaningful emoji reaction on incoming human message.
// ReactionManager encapsulates the state-machine catalogue + per-message
// remove+add transitions. State→emoji defaults match the doctrine table
// in `commands/slacker.md`; overrides come from a `<!-- emoji-overrides -->`
// block in the project's learnings/slacker.md.

export const DEFAULT_REACTION_CATALOGUE: Record<string, string> = {
  received: 'eyes',
  thinking: 'thinking_face',
  done: 'white_check_mark',
  refusing: 'x',
  escalated: 'rotating_light',
};

const VALID_STATES = Object.keys(DEFAULT_REACTION_CATALOGUE);

// parseOverrides — exported for unit testing. Parses the
// `<!-- emoji-overrides -->` HTML-comment block in a learnings file.
// Returns a Map<stateName, emojiName>. Missing file / absent block → empty.
export function parseOverrides(path: string | undefined | null): Map<string, string> {
  const out = new Map<string, string>();
  if (!path || !existsSync(path)) return out;
  const raw = readFileSync(path, 'utf8');
  const m = raw.match(/<!--\s*emoji-overrides\s*-->([\s\S]*?)<!--\s*\/emoji-overrides\s*-->/);
  if (!m || !m[1]) return out;
  for (const rawLine of m[1].split('\n')) {
    const line = rawLine.replace(/\r$/, '').trim();
    if (!line || line.startsWith('#') || line.startsWith('<!--')) continue;
    const kv = line.match(/^([a-z_-]+)\s*=\s*(\S+)$/);
    if (!kv || !kv[1] || !kv[2]) continue;
    const state = kv[1];
    const emoji = kv[2];
    if (VALID_STATES.includes(state)) out.set(state, emoji);
  }
  return out;
}

export interface SetStateResult {
  previous: string | null;
  current: string;
}

export class ReactionManager {
  private readonly catalogue: Map<string, string>;
  private readonly currentReactions = new Map<string, string>();
  private readonly client: WebClient;
  // Bug 0008 fix (Story 163): cache the bot's own Slack user id so
  // lazyReconcile can identify the bot's prior reaction across restarts.
  // Populated lazily via auth.test on first need; null until resolved.
  private botUserId: string | null = null;

  constructor(client: WebClient, learningsPath?: string | null) {
    this.client = client;
    this.catalogue = new Map(Object.entries(DEFAULT_REACTION_CATALOGUE));
    for (const [state, emoji] of parseOverrides(learningsPath)) {
      this.catalogue.set(state, emoji);
    }
  }

  // Test seam: inject bot user id directly (production lazy-fetches via
  // auth.test on first lazyReconcile call). Used by the behavioral test.
  _setBotUserIdForTest(id: string | null): void {
    this.botUserId = id;
  }

  // Test seam: seed the in-memory map directly. Production callers use
  // setState (which performs the reconciliation).
  _seedForTest(channel: string, ts: string, emoji: string): void {
    this.currentReactions.set(`${channel}:${ts}`, emoji);
  }

  // Test seam: read the catalogue (for the defaults-check bash test).
  catalogueEntries(): Record<string, string> {
    return Object.fromEntries(this.catalogue);
  }

  resolveEmoji(stateName: string): string | undefined {
    return this.catalogue.get(stateName);
  }

  // setState — the state-machine entry point. Lookup current → remove (best-
  // effort; no_reaction is non-blocking) → add → update map → return the
  // transition. Lazy reconcile: if the in-memory map has no entry for this
  // ts but the bridge restarted, ask Slack via reactions.get for whatever the
  // bot's own prior reaction was on this message and seed the map before
  // proceeding. This keeps the remove+add invariant after restart.
  async setState(channel: string, ts: string, stateName: string): Promise<SetStateResult> {
    const emoji = this.resolveEmoji(stateName);
    if (!emoji) {
      const err = new Error(`unknown state: ${stateName}`);
      (err as Error & { code?: string }).code = 'UNKNOWN_STATE';
      throw err;
    }
    const key = `${channel}:${ts}`;
    let previous = this.currentReactions.get(key) ?? null;
    if (previous === null) {
      previous = await this.lazyReconcile(channel, ts);
      if (previous) this.currentReactions.set(key, previous);
    }
    if (previous && previous !== emoji) {
      try {
        await this.client.reactions.remove({ channel, timestamp: ts, name: previous });
      } catch (err) {
        const slackErr = (err as { data?: { error?: string } })?.data?.error;
        if (slackErr !== 'no_reaction') throw err;
      }
    }
    if (previous !== emoji) {
      await this.client.reactions.add({ channel, timestamp: ts, name: emoji });
    }
    this.currentReactions.set(key, emoji);
    return { previous, current: emoji };
  }

  // lazyReconcile — query Slack for the bot's prior reaction on this message
  // after a bridge restart cleared the in-memory map. Returns the emoji name
  // if the bot reacted earlier, or null otherwise. Errors are non-fatal —
  // the bridge degrades to "no previous, add only" rather than blocking the
  // current setState call.
  //
  // Bug 0008 fix (Story 163): identify the bot via auth.test (cached after
  // first call), then look for any reaction whose `users` array includes
  // the bot's user id. The pre-fix version always returned null even when
  // a reaction existed, which broke the "remove+add invariant across
  // restarts" promised at slacker.md (reactions stacked instead of
  // replacing). Both error paths (auth.test failure, reactions.get failure)
  // remain non-fatal — caller falls back to "no previous, add only."
  private async lazyReconcile(channel: string, ts: string): Promise<string | null> {
    if (this.botUserId === null) {
      try {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- slack-sdk auth.test response shape is loose
        const authResp = (await this.client.auth.test()) as any;
        const id = authResp?.user_id;
        if (typeof id === 'string' && id.length > 0) {
          this.botUserId = id;
        }
      } catch {
        return null;
      }
    }
    if (this.botUserId === null) return null;
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- slack-sdk's reactions.get response shape is loose
      const resp = (await this.client.reactions.get({ channel, timestamp: ts })) as any;
      const reactions = resp?.message?.reactions ?? [];
      for (const r of reactions) {
        const users = Array.isArray(r?.users) ? r.users : [];
        if (users.includes(this.botUserId)) {
          return typeof r?.name === 'string' ? r.name : null;
        }
      }
      return null;
    } catch {
      return null;
    }
  }
}
