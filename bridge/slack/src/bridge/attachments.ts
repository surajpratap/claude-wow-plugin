import { existsSync, mkdirSync, readFileSync, readdirSync, rmdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { join, basename, extname } from 'node:path';

// Story 157 — download inbound Slack message attachments to disk so CC can
// Read them natively (LLM vision for images, plain Read for text/JSON/PDF).
// The bridge does the HTTPS GET with the bot token, atomic-writes the file,
// and enriches the feed event's attachments array with local paths.

export interface SlackFile {
  id?: string;
  name?: string;
  mimetype?: string;
  filetype?: string;
  size?: number;
  url_private_download?: string;
}

export interface EnrichedAttachment {
  path?: string;
  mime: string | null;
  original_filename: string | null;
  size: number | null;
  slack_file_id: string | null;
  skipped?: boolean;
  skip_reason?: string;
}

const DEFAULT_ALLOW = ['image/*', 'application/pdf', 'text/*', 'application/json', 'application/yaml', 'application/x-yaml'];
const DEFAULT_BLOCK = ['exe', 'dmg', 'app', 'iso', 'bin'];
const DEFAULT_MAX_BYTES = 25 * 1024 * 1024;
const DEFAULT_RETENTION_DAYS = 7;

// parseOverrides — exported for unit testing. Parses the
// `<!-- attachment-mimes -->` block in a learnings file. Override
// REPLACES defaults (does not merge — explicit > implicit, per design spec).
export function parseOverrides(path: string | undefined | null): { allow?: string[]; block?: string[] } {
  if (!path || !existsSync(path)) return {};
  const raw = readFileSync(path, 'utf8');
  const m = raw.match(/<!--\s*attachment-mimes\s*-->([\s\S]*?)<!--\s*\/attachment-mimes\s*-->/);
  if (!m || !m[1]) return {};
  const body = m[1];
  const out: { allow?: string[]; block?: string[] } = {};
  let current: 'allow' | 'block' | null = null;
  for (const rawLine of body.split('\n')) {
    const line = rawLine.replace(/\r$/, '');
    const sectionMatch = line.match(/^\s*(allow|block):\s*$/);
    if (sectionMatch && (sectionMatch[1] === 'allow' || sectionMatch[1] === 'block')) {
      current = sectionMatch[1];
      out[current] = [];
      continue;
    }
    const itemMatch = line.match(/^\s+-\s+(\S+)$/);
    if (itemMatch && current && itemMatch[1]) {
      out[current]?.push(itemMatch[1]);
    }
  }
  return out;
}

// pathSafe — adversarial-filename sanitizer. Strips null bytes, replaces
// path separators + colons with underscore, collapses `..` segments to `_`,
// truncates while preserving the extension, and returns `_unnamed_` on empty.
export function pathSafe(name: string | undefined | null): string {
  if (!name) return '_unnamed_';
  let n = name.replace(/\0/g, '');
  n = n.replace(/[/\\:]/g, '_');
  n = n.replace(/\.\.+/g, '_');
  // Collapse runs of `_` so adversarial inputs (e.g., ../../etc/passwd.png →
  // .._.._etc_passwd.png after the first two passes) reduce to a single
  // leading sanitization sentinel rather than a marker string of underscores.
  n = n.replace(/_+/g, '_');
  if (n.length > 200) {
    const ext = extname(n);
    const base = n.slice(0, 200 - ext.length);
    n = base + ext;
  }
  return n.length > 0 ? n : '_unnamed_';
}

// classifyFile — pure, exported for unit testing. Pre-filter that decides
// whether a file should be downloaded. Block list (by filetype) wins over
// allow list (by mime). Size cap is a hard exit.
export function classifyFile(
  file: SlackFile,
  allow: string[],
  block: string[],
  maxBytes: number,
): { allowed: boolean; reason?: string } {
  if ((file.size ?? 0) > maxBytes) {
    return { allowed: false, reason: `exceeds WOW_SLACK_ATTACHMENT_MAX_BYTES (${maxBytes})` };
  }
  if (file.filetype && block.includes(file.filetype)) {
    return { allowed: false, reason: `filetype blocked: ${file.filetype}` };
  }
  const mime = file.mimetype ?? '';
  const allowed = allow.some((pattern) => {
    if (pattern.endsWith('/*')) {
      const prefix = pattern.slice(0, -1);
      return mime.startsWith(prefix);
    }
    return mime === pattern;
  });
  if (!allowed) {
    return { allowed: false, reason: `mime not allowed: ${mime || '(unknown)'}` };
  }
  return { allowed: true };
}

export class Attachments {
  private readonly baseDir: string;
  private readonly maxBytes: number;
  private readonly retentionMs: number;
  private readonly botToken: string;
  private readonly allow: string[];
  private readonly block: string[];

  constructor(opts: {
    baseDir: string;
    botToken: string;
    maxBytes?: number;
    retentionDays?: number;
    overridesPath?: string;
  }) {
    this.baseDir = opts.baseDir;
    this.botToken = opts.botToken;
    this.maxBytes = opts.maxBytes ?? DEFAULT_MAX_BYTES;
    this.retentionMs = (opts.retentionDays ?? DEFAULT_RETENTION_DAYS) * 24 * 60 * 60 * 1000;
    const overrides = parseOverrides(opts.overridesPath);
    this.allow = overrides.allow ?? DEFAULT_ALLOW;
    this.block = overrides.block ?? DEFAULT_BLOCK;
  }

  // downloadForMessage — serial per file. Returns one entry per inbound file
  // (downloaded or skipped). A per-file failure logs + degrades to skipped;
  // it never throws or aborts the whole message.
  async downloadForMessage(files: SlackFile[], messageTs: string): Promise<EnrichedAttachment[]> {
    if (!files || files.length === 0) return [];
    const dir = join(this.baseDir, messageTs);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const out: EnrichedAttachment[] = [];
    let counter = 1;
    for (const f of files) {
      const verdict = classifyFile(f, this.allow, this.block, this.maxBytes);
      if (!verdict.allowed) {
        out.push({
          mime: f.mimetype ?? null,
          original_filename: f.name ?? null,
          size: f.size ?? null,
          slack_file_id: f.id ?? null,
          skipped: true,
          skip_reason: verdict.reason ?? 'filtered',
        });
        continue;
      }
      const idx = String(counter).padStart(4, '0');
      counter += 1;
      const safe = pathSafe(f.name);
      const fullPath = join(dir, `${idx}-${safe}`);
      try {
        await this.download(f.url_private_download ?? '', fullPath);
        out.push({
          path: fullPath,
          mime: f.mimetype ?? null,
          original_filename: f.name ?? null,
          size: f.size ?? null,
          slack_file_id: f.id ?? null,
        });
      } catch (err) {
        console.warn(`[bridge] attachment download failed for ${f.name}:`, err);
        out.push({
          mime: f.mimetype ?? null,
          original_filename: f.name ?? null,
          size: f.size ?? null,
          slack_file_id: f.id ?? null,
          skipped: true,
          skip_reason: `download failed: ${(err as Error).message}`,
        });
      }
    }
    return out;
  }

  private async download(url: string, destPath: string): Promise<void> {
    if (!url) throw new Error('missing url_private_download');
    const resp = await fetch(url, {
      headers: { Authorization: `Bearer ${this.botToken}` },
    });
    if (!resp.ok) {
      throw new Error(`HTTP ${resp.status}`);
    }
    const buf = Buffer.from(await resp.arrayBuffer());
    writeFileSync(destPath, buf, { mode: 0o600 });
  }

  // cleanup — walk baseDir, unlink files older than retentionMs, then
  // remove empty <message_ts> subdirs.
  async cleanup(): Promise<void> {
    if (!existsSync(this.baseDir)) return;
    const now = Date.now();
    for (const sub of readdirSync(this.baseDir)) {
      const subDir = join(this.baseDir, sub);
      let st;
      try { st = statSync(subDir); } catch { continue; }
      if (!st.isDirectory()) continue;
      let entries: string[] = [];
      try { entries = readdirSync(subDir); } catch { continue; }
      for (const f of entries) {
        const full = join(subDir, f);
        try {
          const fSt = statSync(full);
          if (fSt.isFile() && now - fSt.mtimeMs > this.retentionMs) {
            unlinkSync(full);
          }
        } catch {
          /* ignore — file may have been removed already */
        }
      }
      try {
        if (readdirSync(subDir).length === 0) rmdirSync(subDir);
      } catch {
        /* non-empty or already gone — fine */
      }
    }
  }

  // Test seam — exposes the resolved allow/block lists for fixture inspection.
  getLists(): { allow: string[]; block: string[] } {
    return { allow: this.allow, block: this.block };
  }
}
