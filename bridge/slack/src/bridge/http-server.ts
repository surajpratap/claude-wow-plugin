import { createServer, type IncomingMessage, type ServerResponse, type Server } from 'node:http';
import type { SlackOps } from './slack-ops.js';
import type { SlackResolver } from './cache.js';

// Real socket-mode state snapshot. Populated from Bolt's SocketModeClient
// events in index.ts; /health reflects this directly so the S agent sees
// the truth rather than a hardcoded "connected" string.
export interface SocketState {
  // One of 'connecting' | 'connected' | 'reconnecting' | 'disconnecting'
  // | 'disconnected' | 'failed' | 'unknown'. Free-form string so new
  // socket-mode states don't require type churn here.
  status: string;
  // Set to a short description when status flips to an unhealthy state
  // (disconnect reason, error message, etc.). Cleared on reconnect.
  reason?: string;
  // ISO timestamp of the most recent state transition; lets S tell how
  // long we've been in the current state.
  changedAt: string;
}

// Optional channel-scope the bridge enforces. When set, every inbound
// event with a different channel id is silently dropped (no feed write),
// and every outbound HTTP call that targets a different channel returns
// 403. When null, the bridge accepts all channels (legacy behavior).
export interface ChannelScope {
  id: string;
  name: string | null;
}

interface HttpContext {
  ops: SlackOps;
  resolver: SlackResolver;
  upSince: string;
  state: SocketState;
  scope: ChannelScope | null;
  port: number;
  eventsPath: string;
}

// Tiny localhost-only HTTP API the S agent calls via curl to drive the bot.
// No framework, no auth (binds to 127.0.0.1). Responses are always JSON.
export function startHttpServer(args: {
  port: number;
  eventsPath: string;
  ops: SlackOps;
  resolver: SlackResolver;
  state: SocketState;
  scope: ChannelScope | null;
}): Server {
  const ctx: HttpContext = {
    ops: args.ops,
    resolver: args.resolver,
    upSince: new Date().toISOString(),
    state: args.state,
    scope: args.scope,
    port: args.port,
    eventsPath: args.eventsPath,
  };

  const server = createServer((req, res) => {
    handle(req, res, ctx).catch((err) => {
      console.error('[http] unhandled error:', err);
      if (!res.headersSent) {
        sendJson(res, 500, { ok: false, error: String(err?.message ?? err) });
      }
    });
  });

  server.listen(args.port, '127.0.0.1', () => {
    console.log(`[http] localhost API on http://127.0.0.1:${args.port}`);
  });

  return server;
}

async function handle(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HttpContext,
): Promise<void> {
  const url = new URL(req.url ?? '/', `http://127.0.0.1`);
  const method = req.method ?? 'GET';
  const path = url.pathname;

  if (method === 'GET' && path === '/health') {
    // Healthy iff socket-mode reports Connected. Every other state
    // (connecting, reconnecting, disconnected, failed, unknown) is
    // reported as ok:false so the S agent can escalate to M.
    const healthy = ctx.state.status === 'connected';
    return sendJson(res, healthy ? 200 : 503, {
      ok: healthy,
      socketMode: ctx.state.status,
      reason: ctx.state.reason,
      changedAt: ctx.state.changedAt,
      upSince: ctx.upSince,
      // `scope` tells the S agent which channel this bridge is pinned to
      // (or null for legacy unscoped mode). S uses this to sanity-check
      // its own learnings on startup.
      scope: ctx.scope,
      // `port` and `eventsPath` echo the resolved env-var contract so the
      // S agent can assert the bridge bound to the requested port and
      // writes to the requested path (catches BRIDGE_HTTP_PORT /
      // BRIDGE_DATA_DIR drift where the bridge silently defaults).
      port: ctx.port,
      eventsPath: ctx.eventsPath,
    });
  }

  // Outbound guard: when a channel scope is set, HTTP routes that send,
  // edit, delete, or react in a channel must target the scoped channel.
  // Anything else → 403 with a clear message so the caller notices
  // their bug rather than silently drifting.
  const enforceScope = (channel: string | undefined): boolean => {
    if (!ctx.scope) return true;
    if (!channel) return false;
    return channel === ctx.scope.id;
  };
  const scopeDeny = (res: ServerResponse, channel: string | undefined): void => {
    sendJson(res, 403, {
      ok: false,
      error: 'channel not in scope',
      scope: ctx.scope,
      got: channel ?? null,
    });
  };

  if (method === 'GET' && path === '/conversations') {
    const result = await ctx.ops.conversations();
    return sendJson(res, 200, { ok: true, ...result });
  }

  if (method === 'GET' && path === '/thread') {
    const channel = url.searchParams.get('channel');
    const ts = url.searchParams.get('ts');
    if (!channel || !ts) {
      return sendJson(res, 400, { ok: false, error: 'channel and ts required' });
    }
    if (!enforceScope(channel)) return scopeDeny(res, channel);
    const result = await ctx.ops.thread({ channel, ts });
    return sendJson(res, 200, { ok: true, ...result });
  }

  const channelMatch = path.match(/^\/channel\/([^/]+)$/);
  if (method === 'GET' && channelMatch?.[1]) {
    const info = await ctx.resolver.channel(channelMatch[1]);
    if (!info) return sendJson(res, 404, { ok: false, error: 'channel not found' });
    return sendJson(res, 200, { ok: true, channel: info });
  }

  const userMatch = path.match(/^\/user\/([^/]+)$/);
  if (method === 'GET' && userMatch?.[1]) {
    const info = await ctx.resolver.user(userMatch[1]);
    if (!info) return sendJson(res, 404, { ok: false, error: 'user not found' });
    return sendJson(res, 200, { ok: true, user: info });
  }

  if (method === 'POST' && path === '/send') {
    const body = await readJson<{
      channel: string;
      text?: string;
      blocks?: unknown[];
      threadTs?: string;
    }>(req);
    if (!body.channel) return sendJson(res, 400, { ok: false, error: 'channel required' });
    if (!enforceScope(body.channel)) return scopeDeny(res, body.channel);
    const result = await ctx.ops.send({
      channel: body.channel,
      text: body.text,
      blocks: body.blocks as never,
      threadTs: body.threadTs,
    });
    return sendJson(res, 200, { ok: true, ...result });
  }

  if (method === 'POST' && path === '/reply') {
    const body = await readJson<{
      channel: string;
      threadTs: string;
      text?: string;
      blocks?: unknown[];
    }>(req);
    if (!body.channel || !body.threadTs) {
      return sendJson(res, 400, { ok: false, error: 'channel and threadTs required' });
    }
    if (!enforceScope(body.channel)) return scopeDeny(res, body.channel);
    const result = await ctx.ops.send({
      channel: body.channel,
      threadTs: body.threadTs,
      text: body.text,
      blocks: body.blocks as never,
    });
    return sendJson(res, 200, { ok: true, ...result });
  }

  if (method === 'POST' && path === '/edit') {
    const body = await readJson<{
      channel: string;
      ts: string;
      text?: string;
      blocks?: unknown[];
    }>(req);
    if (!body.channel || !body.ts) {
      return sendJson(res, 400, { ok: false, error: 'channel and ts required' });
    }
    if (!enforceScope(body.channel)) return scopeDeny(res, body.channel);
    const result = await ctx.ops.edit({
      channel: body.channel,
      ts: body.ts,
      text: body.text,
      blocks: body.blocks as never,
    });
    return sendJson(res, 200, result);
  }

  if (method === 'POST' && path === '/delete') {
    const body = await readJson<{ channel: string; ts: string }>(req);
    if (!body.channel || !body.ts) {
      return sendJson(res, 400, { ok: false, error: 'channel and ts required' });
    }
    if (!enforceScope(body.channel)) return scopeDeny(res, body.channel);
    const result = await ctx.ops.remove({ channel: body.channel, ts: body.ts });
    return sendJson(res, 200, result);
  }

  if (method === 'POST' && path === '/reaction/add') {
    const body = await readJson<{ channel: string; ts: string; name: string }>(req);
    if (!body.channel || !body.ts || !body.name) {
      return sendJson(res, 400, { ok: false, error: 'channel, ts, name required' });
    }
    if (!enforceScope(body.channel)) return scopeDeny(res, body.channel);
    const result = await ctx.ops.addReaction(body);
    return sendJson(res, 200, result);
  }

  if (method === 'POST' && path === '/reaction/remove') {
    const body = await readJson<{ channel: string; ts: string; name: string }>(req);
    if (!body.channel || !body.ts || !body.name) {
      return sendJson(res, 400, { ok: false, error: 'channel, ts, name required' });
    }
    if (!enforceScope(body.channel)) return scopeDeny(res, body.channel);
    const result = await ctx.ops.removeReaction(body);
    return sendJson(res, 200, result);
  }

  sendJson(res, 404, { ok: false, error: `no route: ${method} ${path}` });
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const buf = Buffer.from(JSON.stringify(body), 'utf8');
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': buf.length,
  });
  res.end(buf);
}

async function readJson<T>(req: IncomingMessage): Promise<T> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (c: Buffer) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({} as T);
      try {
        resolve(JSON.parse(raw) as T);
      } catch (err) {
        reject(new Error(`invalid JSON body: ${String((err as Error).message)}`));
      }
    });
    req.on('error', reject);
  });
}
