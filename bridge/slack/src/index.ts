import 'dotenv/config';
import { App } from '@slack/bolt';
import { resolve } from 'node:path';
import { mkdirSync, writeFileSync, unlinkSync } from 'node:fs';
import { FeedWriter } from './bridge/feed-writer.js';
import { SlackResolver } from './bridge/cache.js';
import { SlackOps } from './bridge/slack-ops.js';
import { registerHandlers } from './bridge/handlers.js';
import { startHttpServer, type SocketState, type ChannelScope } from './bridge/http-server.js';

// Parse --channel <name-or-id> from CLI argv (CLI wins over env var).
// Accepts `--channel foo`, `--channel=foo`, `-c foo`, `-c=foo`. Single
// value — multi-channel scope isn't supported (keeps the enforcement
// predicate O(1) and matches the single-team-per-bridge mental model).
function parseChannelArg(argv: string[]): string | undefined {
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--channel' || a === '-c') return argv[i + 1];
    if (a?.startsWith('--channel=')) return a.slice('--channel='.length);
    if (a?.startsWith('-c=')) return a.slice('-c='.length);
  }
  return undefined;
}

// Top-level safety net: any error that escapes Bolt's socket-mode state
// machine (e.g. the known finity "Unhandled event in state 'connecting'"
// on auth/handshake issues) would otherwise crash without a clean exit
// code. Log it and exit 1 so the supervisor / human restarts cleanly.
process.on('uncaughtException', (err) => {
  console.error('[claude-slack-bridge] uncaughtException — exiting:', err);
  process.exit(1);
});
process.on('unhandledRejection', (reason) => {
  console.error('[claude-slack-bridge] unhandledRejection — exiting:', reason);
  process.exit(1);
});

const botToken = process.env.SLACK_BOT_TOKEN;
const appToken = process.env.SLACK_APP_TOKEN;

if (!botToken || !appToken) {
  console.error(
    '[claude-slack-bridge] Missing required env vars. Set SLACK_BOT_TOKEN (xoxb-) and SLACK_APP_TOKEN (xapp-) — see .env.example.',
  );
  process.exit(1);
}

const httpPort = Number(process.env.BRIDGE_HTTP_PORT ?? 3100);
const dataDir = resolve(process.env.BRIDGE_DATA_DIR ?? './data');
const eventsFilePath = resolve(dataDir, 'events.jsonl');
const pidFilePath = resolve(dataDir, '.bridge-pid');

mkdirSync(dataDir, { recursive: true });
writeFileSync(pidFilePath, String(process.pid));

// Optional single-channel scope: bridge will ignore every inbound event
// and refuse every outbound HTTP call whose channel differs from this
// one. CLI flag (--channel / -c) wins over env var so operators can
// override at invocation time without editing .env.
const channelInput = parseChannelArg(process.argv.slice(2)) ?? process.env.BRIDGE_CHANNEL;

const app = new App({
  token: botToken,
  appToken,
  socketMode: true,
});

const feed = new FeedWriter(eventsFilePath);
const resolver = new SlackResolver(app.client);

// Shared, mutable snapshot of the socket-mode connection state. The
// http-server's /health endpoint reads this on every request, so any
// flip here instantly changes what the S agent sees via curl.
const state: SocketState = {
  status: 'unknown',
  changedAt: new Date().toISOString(),
};

function setState(status: string, reason?: string): void {
  state.status = status;
  state.reason = reason;
  state.changedAt = new Date().toISOString();
  console.log(`[claude-slack-bridge] socket-mode → ${status}${reason ? ` (${reason})` : ''}`);
}

let ops: SlackOps | null = null;
let httpServer: ReturnType<typeof startHttpServer> | null = null;
let shuttingDown = false;

async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`\n[claude-slack-bridge] ${signal} received, stopping...`);
  try {
    await app.stop();
  } catch (err) {
    console.error('[claude-slack-bridge] error stopping Bolt:', err);
  }
  if (httpServer) {
    await new Promise<void>((r) => httpServer?.close(() => r()));
  }
  try { unlinkSync(pidFilePath); } catch {}
  process.exit(0);
}

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    void shutdown(signal);
  });
}

(async () => {
  // Resolve our own bot user ID once so handlers can suppress self-echoes
  // and so outbound ops can attribute bot_sent entries correctly.
  const authResp = await app.client.auth.test();
  const botUserId = authResp.user_id;
  if (!botUserId) {
    throw new Error('auth.test returned no user_id');
  }
  console.log(`[claude-slack-bridge] bot user id: ${botUserId}`);

  ops = new SlackOps(app.client, feed, resolver, botUserId);

  // Resolve the optional channel scope before we register handlers so the
  // closure over `scope` is correct from the first event. Prefix-detect:
  //   C… = public channel id, D… = DM id, G… = private/group id.
  // Anything else is treated as a human-readable name looked up via
  // conversations.list. Startup aborts if a non-empty scope can't be
  // resolved — we'd rather fail loud than silently accept-all.
  let scope: ChannelScope | null = null;
  if (channelInput) {
    const isId = /^[CDG][A-Z0-9]+$/.test(channelInput);
    if (isId) {
      const info = await resolver.channel(channelInput);
      scope = { id: channelInput, name: info?.name ?? null };
    } else {
      const info = await resolver.channelByName(channelInput);
      if (!info) {
        throw new Error(
          `Channel "${channelInput}" not found in workspace (via conversations.list). ` +
            `Make sure the bot is invited to it, or pass the channel id (starts with C/D/G) instead.`,
        );
      }
      scope = { id: info.id, name: info.name };
    }
    console.log(`[claude-slack-bridge] channel scope: ${scope.name ?? '?'} (${scope.id})`);
  } else {
    console.log('[claude-slack-bridge] channel scope: ALL (unscoped)');
  }

  registerHandlers({ app, feed, resolver, botUserId, scope });

  httpServer = startHttpServer({ port: httpPort, eventsPath: eventsFilePath, ops, resolver, state, scope });

  // Subscribe to Bolt's SocketModeClient events so the shared state snapshot
  // (and thus /health) reflects reality. Bolt's public shape doesn't expose
  // the receiver.client typing cleanly; cast through `unknown` to reach the
  // underlying EventEmitter. If Bolt's internal layout changes, the bridge
  // falls back to status='unknown' and /health reports unhealthy — safe.
  type EmitterLike = {
    on: (event: string, fn: (payload?: unknown) => void) => void;
  };
  // Bolt marks `receiver` as private in its public types even though the
  // runtime field is populated; double-cast to reach it without hitting
  // TS's private-access check or needing a suppression directive.
  const appInternal = app as unknown as { receiver?: { client?: EmitterLike } };
  const socketClient = appInternal.receiver?.client;
  if (socketClient && typeof socketClient.on === 'function') {
    socketClient.on('connecting', () => setState('connecting'));
    socketClient.on('connected', () => setState('connected'));
    socketClient.on('reconnecting', () => setState('reconnecting'));
    socketClient.on('disconnecting', () => setState('disconnecting'));
    socketClient.on('disconnected', () => setState('disconnected'));
    socketClient.on('error', (err?: unknown) => {
      const msg = err instanceof Error ? err.message : String(err ?? 'unknown');
      setState('failed', msg);
    });
  } else {
    console.warn('[claude-slack-bridge] SocketModeClient events unavailable; /health will report "unknown"');
  }

  await app.start();
  console.log('⚡ Bolt running in Socket Mode');
  console.log(`[claude-slack-bridge] events feed: ${eventsFilePath}`);
})().catch((err) => {
  console.error('[claude-slack-bridge] fatal startup error:', err);
  process.exit(1);
});
