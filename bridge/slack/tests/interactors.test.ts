// interactors.test.ts — node:test unit cases for the Interactors registry.
// Runs via `node --test --import tsx tests/interactors.test.ts`.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { Interactors, classifyTechnicality, parseOverrides } from '../src/bridge/interactors.js';

function freshStore(): string {
  const dir = mkdtempSync(join(tmpdir(), 'interactors-'));
  return join(dir, 'interactors.json');
}

// Minimal fake WebClient for ensureInteractor — pretends to be Slack's
// WebClient.users.info but returns a canned profile per user_id. Avoids
// pulling @slack/web-api's full surface into the unit tests.
function fakeClient(profileByUid: Record<string, { name?: string; real_name?: string; title?: string; email?: string }>): any {
  let infoCalls = 0;
  return {
    users: {
      info: async ({ user }: { user: string }) => {
        infoCalls += 1;
        const p = profileByUid[user];
        if (!p) return { user: { id: user, name: user, profile: {} } };
        return {
          user: {
            id: user,
            name: p.name ?? user,
            profile: {
              display_name: p.name,
              real_name: p.real_name,
              title: p.title,
              email: p.email,
            },
          },
        };
      },
    },
    get infoCalls() {
      return infoCalls;
    },
  };
}

// ─── classifyTechnicality matrix ─────────────────────────────────────────────

test('classifyTechnicality: no title → false (conservative default)', () => {
  assert.equal(classifyTechnicality(undefined), false);
  assert.equal(classifyTechnicality(null), false);
  assert.equal(classifyTechnicality(''), false);
});

test('classifyTechnicality: technical title → true', () => {
  assert.equal(classifyTechnicality('Software Engineer'), true);
  assert.equal(classifyTechnicality('SDE III'), true);
  assert.equal(classifyTechnicality('CTO'), true);
  assert.equal(classifyTechnicality('Data Scientist'), true);
  assert.equal(classifyTechnicality('DevOps Lead'), true);
});

test('classifyTechnicality: non-technical title → false', () => {
  assert.equal(classifyTechnicality('Marketing Director'), false);
  assert.equal(classifyTechnicality('VP Sales'), false);
});

test('classifyTechnicality: founder alone → null (ambiguous)', () => {
  assert.equal(classifyTechnicality('Founder'), null);
  assert.equal(classifyTechnicality('Co-Founder'), null);
});

test('classifyTechnicality: founder + technical → true', () => {
  assert.equal(classifyTechnicality('Founder & CTO'), true);
  assert.equal(classifyTechnicality('Founding Engineer'), true);
});

// ─── parseOverrides ──────────────────────────────────────────────────────────

test('parseOverrides: missing file → empty map', () => {
  const map = parseOverrides('/nonexistent/path/learnings.md');
  assert.equal(map.size, 0);
});

test('parseOverrides: absent block → empty map', () => {
  const dir = mkdtempSync(join(tmpdir(), 'overrides-'));
  const f = join(dir, 'learnings.md');
  writeFileSync(f, '# Learnings\n\nNo override block here.\n');
  const map = parseOverrides(f);
  assert.equal(map.size, 0);
  rmSync(dir, { recursive: true, force: true });
});

test('parseOverrides: block with one user → map entry with merged fields', () => {
  const dir = mkdtempSync(join(tmpdir(), 'overrides-'));
  const f = join(dir, 'learnings.md');
  writeFileSync(
    f,
    `# Learnings

<!-- interactor-overrides -->
U01ABC:
  name: Alice
  title: Chief Plain-Speaker
  technical: false
U02XYZ:
  role: stakeholder
  technical: true
<!-- /interactor-overrides -->
`,
  );
  const map = parseOverrides(f);
  assert.equal(map.size, 2);
  const alice = map.get('U01ABC');
  assert.ok(alice);
  assert.equal(alice.name, 'Alice');
  assert.equal(alice.title, 'Chief Plain-Speaker');
  assert.equal(alice.technical, false);
  const bob = map.get('U02XYZ');
  assert.ok(bob);
  assert.equal(bob.role, 'stakeholder');
  assert.equal(bob.technical, true);
  rmSync(dir, { recursive: true, force: true });
});

// ─── Interactors ensureInteractor ────────────────────────────────────────────

test('ensureInteractor: first contact creates record + persists with mode 0600', async () => {
  const path = freshStore();
  const reg = new Interactors({ path });
  const client = fakeClient({ U01: { name: 'Alice', real_name: 'Alice A.', title: 'CTO', email: 'a@x.com' } });
  const rec = await reg.ensureInteractor(client, 'U01');
  assert.equal(rec.user_id, 'U01');
  assert.equal(rec.name, 'Alice');
  assert.equal(rec.title, 'CTO');
  assert.equal(rec.email, 'a@x.com');
  assert.equal(rec.technical, true);
  assert.equal(rec.interaction_count, 1);
  assert.equal(rec.first_seen, rec.last_seen);
  assert.equal(client.infoCalls, 1);
  // Disk persistence + mode
  const mode = statSync(path).mode & 0o777;
  assert.equal(mode, 0o600);
  const disk = JSON.parse(readFileSync(path, 'utf8'));
  assert.ok(disk.interactors.U01);
});

test('ensureInteractor: repeat within TTL → no users.info re-call; bumps interaction_count + last_seen', async () => {
  const path = freshStore();
  const reg = new Interactors({ path, ttlDays: 30 });
  const client = fakeClient({ U01: { name: 'Alice', title: 'CTO' } });
  const r1 = await reg.ensureInteractor(client, 'U01');
  await new Promise((r) => setTimeout(r, 50));
  const r2 = await reg.ensureInteractor(client, 'U01');
  assert.equal(client.infoCalls, 1);
  assert.equal(r2.interaction_count, 2);
  assert.equal(r2.first_seen, r1.first_seen);
  assert.notEqual(r2.last_seen, r1.last_seen);
});

test('ensureInteractor: past TTL → users.info re-called; first_seen preserved', async () => {
  const path = freshStore();
  const reg = new Interactors({ path, ttlDays: 1 });
  const client = fakeClient({ U01: { name: 'Alice', title: 'CTO' } });
  await reg.ensureInteractor(client, 'U01');
  // Seed a fake old profile_fetched_at via the disk file directly
  const disk = JSON.parse(readFileSync(path, 'utf8'));
  disk.interactors.U01.profile_fetched_at = '2000-01-01T00:00:00Z';
  disk.interactors.U01.first_seen = '2000-01-01T00:00:00Z';
  writeFileSync(path, JSON.stringify(disk));
  // Re-instantiate so loadFromDisk picks up the stale fetched_at
  const reg2 = new Interactors({ path, ttlDays: 1 });
  const r2 = await reg2.ensureInteractor(client, 'U01');
  assert.equal(client.infoCalls, 2);
  assert.equal(r2.first_seen, '2000-01-01T00:00:00Z');
  assert.notEqual(r2.profile_fetched_at, '2000-01-01T00:00:00Z');
});

test('ensureInteractor: override merge wins over fresh users.info data', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'interactors-'));
  const path = join(dir, 'interactors.json');
  const overridesPath = join(dir, 'learnings.md');
  writeFileSync(
    overridesPath,
    `<!-- interactor-overrides -->
U01:
  technical: false
  role: stakeholder
<!-- /interactor-overrides -->
`,
  );
  const reg = new Interactors({ path, overridesPath });
  const client = fakeClient({ U01: { name: 'Alice', title: 'Senior Engineer' } });
  const rec = await reg.ensureInteractor(client, 'U01');
  assert.equal(rec.technical, false);
  assert.equal(rec.role, 'stakeholder');
  assert.equal(rec.override_source, 'learnings');
  // Raw record (no override) still reflects the fresh fetch
  const raw = reg.getRaw('U01');
  assert.ok(raw);
  assert.equal(raw.technical, true);
  assert.equal(raw.role, null);
  rmSync(dir, { recursive: true, force: true });
});

test('Interactors: load roundtrip — record from disk re-served on new instance', async () => {
  const path = freshStore();
  const reg1 = new Interactors({ path });
  const client = fakeClient({ U01: { name: 'Alice' } });
  await reg1.ensureInteractor(client, 'U01');
  const reg2 = new Interactors({ path });
  const raw = reg2.getRaw('U01');
  assert.ok(raw);
  assert.equal(raw.name, 'Alice');
});
