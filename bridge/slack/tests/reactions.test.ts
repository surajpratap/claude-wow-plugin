// reactions.test.ts — node:test unit cases for the ReactionManager class.
// Runs via `node --test --import tsx tests/reactions.test.ts`.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  DEFAULT_REACTION_CATALOGUE,
  ReactionManager,
  parseOverrides,
} from '../src/bridge/reactions.js';

// Minimal fake WebClient that records every reactions.add / reactions.remove
// call so the test can assert the remove+add invariant per setState.
function fakeClient(opts: { removeError?: string; reactionsGet?: any; botUserId?: string } = {}): any {
  const calls: Array<{ op: 'add' | 'remove' | 'get' | 'auth.test'; channel: string; ts: string; name?: string }> = [];
  return {
    calls,
    // Bug 0008 fix (Story 163): ReactionManager.lazyReconcile now calls
    // auth.test to identify the bot's user id. The fake returns a stable
    // 'UBOT' (override via opts.botUserId for tests that need a different id).
    auth: {
      test: async () => {
        calls.push({ op: 'auth.test', channel: '', ts: '' });
        return { ok: true, user_id: opts.botUserId ?? 'UBOT' };
      },
    },
    reactions: {
      add: async ({ channel, timestamp, name }: { channel: string; timestamp: string; name: string }) => {
        calls.push({ op: 'add', channel, ts: timestamp, name });
        return { ok: true };
      },
      remove: async ({ channel, timestamp, name }: { channel: string; timestamp: string; name: string }) => {
        calls.push({ op: 'remove', channel, ts: timestamp, name });
        if (opts.removeError) {
          const err = new Error('slack_webapi_platform_error') as Error & { data?: { error?: string } };
          err.data = { error: opts.removeError };
          throw err;
        }
        return { ok: true };
      },
      get: async ({ channel, timestamp }: { channel: string; timestamp: string }) => {
        calls.push({ op: 'get', channel, ts: timestamp });
        return opts.reactionsGet ?? { message: { reactions: [] } };
      },
    },
  };
}

// ─── catalogue defaults ──────────────────────────────────────────────────────

test('defaults: catalogue has 5 known states', () => {
  assert.equal(Object.keys(DEFAULT_REACTION_CATALOGUE).length, 5);
  assert.equal(DEFAULT_REACTION_CATALOGUE.received, 'eyes');
  assert.equal(DEFAULT_REACTION_CATALOGUE.thinking, 'thinking_face');
  assert.equal(DEFAULT_REACTION_CATALOGUE.done, 'white_check_mark');
  assert.equal(DEFAULT_REACTION_CATALOGUE.refusing, 'x');
  assert.equal(DEFAULT_REACTION_CATALOGUE.escalated, 'rotating_light');
});

test('ReactionManager: catalogue defaults match the export', () => {
  const mgr = new ReactionManager(fakeClient());
  const cat = mgr.catalogueEntries();
  assert.deepEqual(cat, DEFAULT_REACTION_CATALOGUE);
});

// ─── parseOverrides ──────────────────────────────────────────────────────────

test('parseOverrides: missing path → empty', () => {
  assert.equal(parseOverrides(undefined).size, 0);
  assert.equal(parseOverrides('/nonexistent').size, 0);
});

test('parseOverrides: absent block → empty', () => {
  const dir = mkdtempSync(join(tmpdir(), 'reactions-'));
  const f = join(dir, 'learnings.md');
  writeFileSync(f, '# Learnings\n\nNo override block.\n');
  assert.equal(parseOverrides(f).size, 0);
  rmSync(dir, { recursive: true, force: true });
});

test('parseOverrides: block with key=value → merged catalogue', () => {
  const dir = mkdtempSync(join(tmpdir(), 'reactions-'));
  const f = join(dir, 'learnings.md');
  writeFileSync(
    f,
    `# Learnings

<!-- emoji-overrides -->
done=tada
received=eyes_open
<!-- /emoji-overrides -->
`,
  );
  const map = parseOverrides(f);
  assert.equal(map.get('done'), 'tada');
  assert.equal(map.get('received'), 'eyes_open');
  rmSync(dir, { recursive: true, force: true });
});

test('parseOverrides: unknown state in block → ignored (drops silently)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'reactions-'));
  const f = join(dir, 'learnings.md');
  writeFileSync(f, `<!-- emoji-overrides -->\nbogus=star\n<!-- /emoji-overrides -->\n`);
  const map = parseOverrides(f);
  assert.equal(map.size, 0);
  rmSync(dir, { recursive: true, force: true });
});

// ─── ReactionManager.setState ────────────────────────────────────────────────

test('setState: first call for unknown ts → no previous, add only', async () => {
  const client = fakeClient();
  const mgr = new ReactionManager(client);
  const r = await mgr.setState('C1', 'T1', 'received');
  assert.equal(r.previous, null);
  assert.equal(r.current, 'eyes');
  const ops = client.calls.map((c: { op: string; name?: string }) => `${c.op}:${c.name ?? ''}`);
  // Bug 0008 fix (Story 163): lazyReconcile now calls auth.test first to
  // identify the bot's user id (cached after first call), then reactions.get
  // to look for the bot's prior reaction.
  assert.deepEqual(ops, ['auth.test:', 'get:', 'add:eyes']);
});

test('setState: second call (transition) → remove + add pair, returns previous', async () => {
  const client = fakeClient();
  const mgr = new ReactionManager(client);
  await mgr.setState('C1', 'T1', 'received');
  client.calls.length = 0;
  const r = await mgr.setState('C1', 'T1', 'thinking');
  assert.equal(r.previous, 'eyes');
  assert.equal(r.current, 'thinking_face');
  const ops = client.calls.map((c: { op: string; name?: string }) => `${c.op}:${c.name ?? ''}`);
  assert.deepEqual(ops, ['remove:eyes', 'add:thinking_face']);
});

test('setState: same state twice → no-op (no remove, no add)', async () => {
  const client = fakeClient();
  const mgr = new ReactionManager(client);
  await mgr.setState('C1', 'T1', 'received');
  client.calls.length = 0;
  const r = await mgr.setState('C1', 'T1', 'received');
  assert.equal(r.previous, 'eyes');
  assert.equal(r.current, 'eyes');
  assert.equal(client.calls.length, 0);
});

test('setState: unknown state → throws UNKNOWN_STATE', async () => {
  const client = fakeClient();
  const mgr = new ReactionManager(client);
  await assert.rejects(
    () => mgr.setState('C1', 'T1', 'bogus'),
    /unknown state: bogus/,
  );
});

test('setState: no_reaction on remove → non-blocking, add still fires', async () => {
  const client = fakeClient({ removeError: 'no_reaction' });
  const mgr = new ReactionManager(client);
  // Seed a prior so remove gets called
  mgr._seedForTest('C1', 'T1', 'eyes');
  const r = await mgr.setState('C1', 'T1', 'thinking');
  assert.equal(r.previous, 'eyes');
  assert.equal(r.current, 'thinking_face');
  const ops = client.calls.map((c: { op: string; name?: string }) => `${c.op}:${c.name ?? ''}`);
  assert.deepEqual(ops, ['remove:eyes', 'add:thinking_face']);
});

test('setState: other Slack remove errors → propagate', async () => {
  const client = fakeClient({ removeError: 'channel_not_found' });
  const mgr = new ReactionManager(client);
  mgr._seedForTest('C1', 'T1', 'eyes');
  await assert.rejects(() => mgr.setState('C1', 'T1', 'thinking'));
});

test('setState: lazy reconcile — unknown ts after bridge restart calls reactions.get', async () => {
  const client = fakeClient();
  const mgr = new ReactionManager(client);
  await mgr.setState('C1', 'T1', 'received');
  // reactions.get was called on the first (cold) call
  const getCalls = client.calls.filter((c: { op: string }) => c.op === 'get');
  assert.equal(getCalls.length, 1);
});

// ─── override-merged catalogue ───────────────────────────────────────────────

test('override-merged catalogue: setState resolves overridden emoji', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'reactions-'));
  const f = join(dir, 'learnings.md');
  writeFileSync(f, `<!-- emoji-overrides -->\ndone=tada\n<!-- /emoji-overrides -->\n`);
  const client = fakeClient();
  const mgr = new ReactionManager(client, f);
  const r = await mgr.setState('C1', 'T1', 'done');
  assert.equal(r.current, 'tada');
  rmSync(dir, { recursive: true, force: true });
});
