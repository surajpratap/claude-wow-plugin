import { readFileSync, writeFileSync, mkdirSync, renameSync, chmodSync, existsSync, statSync } from 'node:fs';
import { dirname } from 'node:path';
import type { WebClient } from '@slack/web-api';

// Story 156 — bridge tracks who's talking to it. The bridge calls Slack's
// users.info once per first-contact user, persists name/title/email/role
// inference to a JSON registry under ~/.wow-kindflow/slack/<project-key>/,
// and merges per-project overrides from a learnings block. S uses the
// resulting `interactor` field on each forwarded event to compose replies
// in the right vocabulary (plain-English vs. technical-jargon).

export interface InteractorRecord {
  user_id: string;
  name: string | null;
  title: string | null;
  email: string | null;
  role: string | null;
  technical: boolean | null;
  first_seen: string;
  last_seen: string;
  interaction_count: number;
  profile_fetched_at: string;
  override_source: string | null;
}

interface OverrideEntry {
  name?: string;
  title?: string;
  email?: string;
  role?: string;
  technical?: boolean | null;
}

// classifyTechnicality — pure heuristic the bridge applies to a Slack
// title string. Exported separately so the unit suite can run a fixture
// matrix without a Slack client. Founder-alone returns null (ambiguous,
// M may ask the human and cache); no-title returns false (conservative
// default — verbose-but-clear is safer than wrong-way jargon).
export function classifyTechnicality(title: string | undefined | null): boolean | null {
  if (!title) return false;
  const lower = title.toLowerCase();
  const hasTech = /\b(engineer|developer|architect|dev|swe|sde|cto|tech\s*lead|data\s*scientist|ml|sre|devops|qa|ops|programmer|coder|hacker)\b/.test(lower);
  const isFounder = /\bfounder\b/.test(lower);
  if (isFounder && hasTech) return true;
  if (isFounder) return null;
  return hasTech;
}

// Parse a learnings file for a `<!-- interactor-overrides -->` block. The
// block body is a simple `<user_id>:` keyed YAML-like list; values override
// the corresponding fields on every ensureInteractor lookup for that user.
// Returns a Map keyed by user_id; absent file or absent block → empty map.
export function parseOverrides(path: string | undefined): Map<string, OverrideEntry> {
  const out = new Map<string, OverrideEntry>();
  if (!path || !existsSync(path)) return out;
  const raw = readFileSync(path, 'utf8');
  const m = raw.match(/<!--\s*interactor-overrides\s*-->([\s\S]*?)<!--\s*\/interactor-overrides\s*-->/);
  if (!m || !m[1]) return out;
  const body = m[1];
  let currentUser: string | null = null;
  let currentEntry: OverrideEntry = {};
  for (const rawLine of body.split('\n')) {
    const line = rawLine.replace(/\r$/, '');
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const userMatch = line.match(/^([UW][A-Z0-9]+):\s*$/);
    if (userMatch && userMatch[1]) {
      if (currentUser) out.set(currentUser, currentEntry);
      currentUser = userMatch[1];
      currentEntry = {};
      continue;
    }
    const fieldMatch = line.match(/^\s+(name|title|email|role|technical):\s*(.*)$/);
    if (fieldMatch && currentUser && fieldMatch[1] !== undefined && fieldMatch[2] !== undefined) {
      const key = fieldMatch[1] as keyof OverrideEntry;
      const value = fieldMatch[2].trim();
      if (key === 'technical') {
        if (value === 'true') currentEntry.technical = true;
        else if (value === 'false') currentEntry.technical = false;
        else if (value === 'null' || value === '') currentEntry.technical = null;
      } else {
        (currentEntry as Record<string, unknown>)[key] = value;
      }
    }
  }
  if (currentUser) out.set(currentUser, currentEntry);
  return out;
}

export class Interactors {
  private records = new Map<string, InteractorRecord>();
  private overrides: Map<string, OverrideEntry>;
  private readonly path: string;
  private readonly overridesPath: string | undefined;
  private readonly ttlMs: number;

  constructor(opts: {
    path: string;
    overridesPath?: string;
    ttlDays?: number;
  }) {
    this.path = opts.path;
    this.overridesPath = opts.overridesPath;
    this.ttlMs = (opts.ttlDays ?? 30) * 24 * 60 * 60 * 1000;
    this.overrides = parseOverrides(this.overridesPath);
    this.loadFromDisk();
  }

  private loadFromDisk(): void {
    if (!existsSync(this.path)) return;
    try {
      const raw = readFileSync(this.path, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object' && parsed.interactors && typeof parsed.interactors === 'object') {
        for (const [uid, rec] of Object.entries(parsed.interactors)) {
          this.records.set(uid, rec as InteractorRecord);
        }
      }
    } catch {
      // Corrupt file — start fresh; persist will overwrite on next save.
    }
  }

  private persist(): void {
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    const payload = JSON.stringify({ interactors: Object.fromEntries(this.records) }, null, 2);
    const tmp = `${this.path}.tmp.${process.pid}`;
    writeFileSync(tmp, payload, { mode: 0o600 });
    renameSync(tmp, this.path);
    try { chmodSync(this.path, 0o600); } catch { /* best-effort */ }
  }

  // Returns a shallow copy so callers cannot mutate the in-store record,
  // and so two sequential calls (which both reuse the stored object) don't
  // alias each other through later in-place last_seen / interaction_count
  // updates.
  private applyOverride(rec: InteractorRecord): InteractorRecord {
    const merged: InteractorRecord = { ...rec };
    const ovr = this.overrides.get(rec.user_id);
    if (!ovr) return merged;
    if (ovr.name !== undefined) merged.name = ovr.name;
    if (ovr.title !== undefined) merged.title = ovr.title;
    if (ovr.email !== undefined) merged.email = ovr.email;
    if (ovr.role !== undefined) merged.role = ovr.role;
    if (ovr.technical !== undefined) merged.technical = ovr.technical;
    merged.override_source = 'learnings';
    return merged;
  }

  // ensureInteractor — the bridge's per-event hook. Returns the record for
  // userId (creating + persisting on first contact, refreshing on TTL
  // expiry, bumping interaction_count + last_seen otherwise). Override
  // block values are applied AFTER the fresh fetch so the human's
  // hand-edited learnings always win.
  async ensureInteractor(client: WebClient, userId: string): Promise<InteractorRecord> {
    const now = new Date().toISOString();
    const existing = this.records.get(userId);
    if (existing) {
      const fetchedAt = new Date(existing.profile_fetched_at).getTime();
      const stale = Date.now() - fetchedAt > this.ttlMs;
      if (!stale) {
        existing.last_seen = now;
        existing.interaction_count += 1;
        this.records.set(userId, existing);
        this.persist();
        return this.applyOverride(existing);
      }
      const refreshed = await this.fetchAndMerge(client, userId, existing, now);
      this.persist();
      return this.applyOverride(refreshed);
    }
    const fresh = await this.fetchAndMerge(client, userId, null, now);
    this.persist();
    return this.applyOverride(fresh);
  }

  private async fetchAndMerge(
    client: WebClient,
    userId: string,
    existing: InteractorRecord | null,
    now: string,
  ): Promise<InteractorRecord> {
    let name: string | null = existing?.name ?? null;
    let title: string | null = existing?.title ?? null;
    let email: string | null = existing?.email ?? null;
    try {
      const resp = await client.users.info({ user: userId });
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- slack-sdk's profile shape is loose
      const profile = (resp.user as any)?.profile ?? {};
      name = profile.display_name || profile.real_name || (resp.user as { name?: string })?.name || null;
      title = profile.title ?? null;
      email = profile.email ?? null;
    } catch {
      // Best-effort — keep prior values if a refresh fails. The record is
      // still persisted so first_seen / interaction_count are not lost.
    }
    const rec: InteractorRecord = {
      user_id: userId,
      name,
      title,
      email,
      role: existing?.role ?? null,
      technical: classifyTechnicality(title),
      first_seen: existing?.first_seen ?? now,
      last_seen: now,
      interaction_count: (existing?.interaction_count ?? 0) + 1,
      profile_fetched_at: now,
      override_source: existing?.override_source ?? null,
    };
    this.records.set(userId, rec);
    return rec;
  }

  // Inspector for unit tests. Returns the on-disk record (without override
  // merge applied) so the test can distinguish disk state from merged state.
  getRaw(userId: string): InteractorRecord | undefined {
    return this.records.get(userId);
  }

  // Test seam — lets the test push synthetic records into the store and
  // re-persist without needing a Slack client. Not used in production.
  _seedForTest(rec: InteractorRecord): void {
    this.records.set(rec.user_id, rec);
    this.persist();
  }

  // Test seam — exposes the persisted-disk mode for fixture inspection.
  static fileMode(path: string): number {
    return statSync(path).mode & 0o777;
  }
}
