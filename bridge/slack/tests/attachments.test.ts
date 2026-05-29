// attachments.test.ts — node:test unit cases for the Attachments class.
// Runs via `node --test --import tsx tests/attachments.test.ts`.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { Attachments, classifyFile, parseOverrides, pathSafe } from '../src/bridge/attachments.js';

// ─── pathSafe matrix ─────────────────────────────────────────────────────────

test('pathSafe: empty/null → _unnamed_', () => {
  assert.equal(pathSafe(undefined), '_unnamed_');
  assert.equal(pathSafe(null), '_unnamed_');
  assert.equal(pathSafe(''), '_unnamed_');
});

test('pathSafe: strips null bytes', () => {
  assert.equal(pathSafe('foo\0bar.png'), 'foobar.png');
});

test('pathSafe: replaces path separators + colons', () => {
  assert.equal(pathSafe('a/b\\c:d.png'), 'a_b_c_d.png');
});

test('pathSafe: collapses .. segments', () => {
  assert.equal(pathSafe('../../etc/passwd.png'), '_etc_passwd.png');
});

test('pathSafe: truncates while preserving extension', () => {
  const long = 'x'.repeat(250) + '.png';
  const safe = pathSafe(long);
  assert.equal(safe.length, 200);
  assert.equal(safe.endsWith('.png'), true);
});

// ─── classifyFile matrix ─────────────────────────────────────────────────────

const allow = ['image/*', 'application/pdf', 'text/*'];
const block = ['exe', 'dmg'];

test('classifyFile: image/png within size → allowed', () => {
  const v = classifyFile({ mimetype: 'image/png', size: 1000 }, allow, block, 1_000_000);
  assert.equal(v.allowed, true);
});

test('classifyFile: over size cap → not allowed', () => {
  const v = classifyFile({ mimetype: 'image/png', size: 2_000_000 }, allow, block, 1_000_000);
  assert.equal(v.allowed, false);
  assert.match(v.reason ?? '', /exceeds/);
});

test('classifyFile: blocked filetype → not allowed', () => {
  const v = classifyFile({ filetype: 'exe', mimetype: 'application/octet-stream', size: 100 }, allow, block, 1_000_000);
  assert.equal(v.allowed, false);
  assert.match(v.reason ?? '', /filetype blocked/);
});

test('classifyFile: mime not in allow → not allowed', () => {
  const v = classifyFile({ mimetype: 'video/mp4', size: 100 }, allow, block, 1_000_000);
  assert.equal(v.allowed, false);
  assert.match(v.reason ?? '', /not allowed/);
});

test('classifyFile: exact mime match (application/pdf)', () => {
  const v = classifyFile({ mimetype: 'application/pdf', size: 100 }, allow, block, 1_000_000);
  assert.equal(v.allowed, true);
});

// ─── parseOverrides ──────────────────────────────────────────────────────────

test('parseOverrides: missing path → empty', () => {
  assert.deepEqual(parseOverrides(undefined), {});
  assert.deepEqual(parseOverrides('/nonexistent'), {});
});

test('parseOverrides: block parses allow + block lists', () => {
  const dir = mkdtempSync(join(tmpdir(), 'att-'));
  const f = join(dir, 'learnings.md');
  writeFileSync(
    f,
    `<!-- attachment-mimes -->
allow:
  - image/png
  - text/*
block:
  - mov
<!-- /attachment-mimes -->
`,
  );
  const parsed = parseOverrides(f);
  assert.deepEqual(parsed.allow, ['image/png', 'text/*']);
  assert.deepEqual(parsed.block, ['mov']);
  rmSync(dir, { recursive: true, force: true });
});

// ─── downloadForMessage with mocked HTTPS ────────────────────────────────────

test('downloadForMessage: happy path — file written + Bearer auth sent', async () => {
  let authHeader: string | null = null;
  const server = createServer((req, res) => {
    authHeader = req.headers['authorization'] ?? null;
    res.writeHead(200, { 'content-type': 'image/png' });
    res.end(Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  const baseDir = mkdtempSync(join(tmpdir(), 'att-'));
  const att = new Attachments({ baseDir, botToken: 'xoxb-test-token' });
  const out = await att.downloadForMessage(
    [{ id: 'F1', name: 'screenshot.png', mimetype: 'image/png', size: 4, url_private_download: `http://127.0.0.1:${port}/file` }],
    '1234.5678',
  );
  await new Promise<void>((r) => server.close(() => r()));
  assert.equal(out.length, 1);
  assert.ok(out[0].path);
  assert.equal(out[0].mime, 'image/png');
  assert.equal(out[0].original_filename, 'screenshot.png');
  assert.equal(out[0].slack_file_id, 'F1');
  assert.equal(authHeader, 'Bearer xoxb-test-token');
  const written = readFileSync(out[0].path as string);
  assert.deepEqual(written, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  rmSync(baseDir, { recursive: true, force: true });
});

test('downloadForMessage: HTTP 404 → skipped with reason', async () => {
  const server = createServer((_, res) => { res.writeHead(404); res.end(); });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  const baseDir = mkdtempSync(join(tmpdir(), 'att-'));
  const att = new Attachments({ baseDir, botToken: 't' });
  const out = await att.downloadForMessage(
    [{ id: 'F1', name: 'x.png', mimetype: 'image/png', size: 1, url_private_download: `http://127.0.0.1:${port}/x` }],
    '1.2',
  );
  await new Promise<void>((r) => server.close(() => r()));
  assert.equal(out[0].skipped, true);
  assert.match(out[0].skip_reason ?? '', /HTTP 404/);
  rmSync(baseDir, { recursive: true, force: true });
});

test('downloadForMessage: counter collision — two files same name → 0001/0002', async () => {
  const server = createServer((_, res) => { res.writeHead(200); res.end('x'); });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  const baseDir = mkdtempSync(join(tmpdir(), 'att-'));
  const att = new Attachments({ baseDir, botToken: 't' });
  const url = `http://127.0.0.1:${port}/x`;
  const out = await att.downloadForMessage(
    [
      { id: 'F1', name: 'screenshot.png', mimetype: 'image/png', size: 1, url_private_download: url },
      { id: 'F2', name: 'screenshot.png', mimetype: 'image/png', size: 1, url_private_download: url },
    ],
    '1.2',
  );
  await new Promise<void>((r) => server.close(() => r()));
  assert.equal(out.length, 2);
  assert.ok(out[0].path?.endsWith('0001-screenshot.png'));
  assert.ok(out[1].path?.endsWith('0002-screenshot.png'));
  rmSync(baseDir, { recursive: true, force: true });
});

test('downloadForMessage: over-cap file → skipped', async () => {
  const baseDir = mkdtempSync(join(tmpdir(), 'att-'));
  const att = new Attachments({ baseDir, botToken: 't', maxBytes: 100 });
  const out = await att.downloadForMessage(
    [{ id: 'F1', name: 'big.png', mimetype: 'image/png', size: 1000, url_private_download: 'http://unused' }],
    '1.2',
  );
  assert.equal(out[0].skipped, true);
  assert.match(out[0].skip_reason ?? '', /exceeds/);
  rmSync(baseDir, { recursive: true, force: true });
});

test('downloadForMessage: blocked filetype → skipped', async () => {
  const baseDir = mkdtempSync(join(tmpdir(), 'att-'));
  const att = new Attachments({ baseDir, botToken: 't' });
  const out = await att.downloadForMessage(
    [{ id: 'F1', name: 'mal.exe', filetype: 'exe', mimetype: 'application/octet-stream', size: 1, url_private_download: 'http://unused' }],
    '1.2',
  );
  assert.equal(out[0].skipped, true);
  assert.match(out[0].skip_reason ?? '', /filetype blocked/);
  rmSync(baseDir, { recursive: true, force: true });
});

test('downloadForMessage: empty files array → empty result', async () => {
  const baseDir = mkdtempSync(join(tmpdir(), 'att-'));
  const att = new Attachments({ baseDir, botToken: 't' });
  const out = await att.downloadForMessage([], '1.2');
  assert.deepEqual(out, []);
  rmSync(baseDir, { recursive: true, force: true });
});

// ─── cleanup boundary ────────────────────────────────────────────────────────

test('cleanup: old files removed; recent retained; empty dirs pruned', async () => {
  const baseDir = mkdtempSync(join(tmpdir(), 'att-'));
  const oldDir = join(baseDir, '1000.0');
  const newDir = join(baseDir, '2000.0');
  for (const d of [oldDir, newDir]) {
    writeFileSync(join(d.replace(/\/[^/]+$/, ''), '.tmp-mkdir-check'), '');
  }
  // Use Node's mkdirSync for actual creation
  const { mkdirSync } = await import('node:fs');
  mkdirSync(oldDir, { recursive: true });
  mkdirSync(newDir, { recursive: true });
  const oldFile = join(oldDir, '0001-x.png');
  const newFile = join(newDir, '0001-y.png');
  writeFileSync(oldFile, 'a');
  writeFileSync(newFile, 'b');
  // Backdate the old file 30 days
  const past = Date.now() / 1000 - 30 * 86400;
  utimesSync(oldFile, past, past);

  const att = new Attachments({ baseDir, botToken: 't', retentionDays: 7 });
  await att.cleanup();

  assert.equal(existsSync(oldFile), false, 'old file should be unlinked');
  assert.equal(existsSync(newFile), true, 'recent file should remain');
  assert.equal(existsSync(oldDir), false, 'empty <ts> dir pruned');
  assert.equal(existsSync(newDir), true, 'dir with recent file retained');

  rmSync(baseDir, { recursive: true, force: true });
});

// ─── override-merged catalogue ───────────────────────────────────────────────

test('override block: replaces defaults (does not merge)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'att-'));
  const f = join(dir, 'learnings.md');
  writeFileSync(
    f,
    `<!-- attachment-mimes -->
allow:
  - image/png
block:
  - mov
<!-- /attachment-mimes -->
`,
  );
  const att = new Attachments({ baseDir: dir, botToken: 't', overridesPath: f });
  const lists = att.getLists();
  assert.deepEqual(lists.allow, ['image/png']);
  assert.deepEqual(lists.block, ['mov']);
  // default mime (application/pdf) is NOT in the override-allow → blocked
  const v = classifyFile({ mimetype: 'application/pdf', size: 100 }, lists.allow, lists.block, 1_000_000);
  assert.equal(v.allowed, false);
  rmSync(dir, { recursive: true, force: true });
});
