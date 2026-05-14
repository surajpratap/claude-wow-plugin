import { appendFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

// Append-only JSONL writer. Serializes writes behind a single promise chain
// so two concurrent appends never interleave on disk.
export class FeedWriter {
  private queue: Promise<void> = Promise.resolve();
  private initialized = false;

  constructor(private filePath: string) {}

  async append(record: Record<string, unknown>): Promise<void> {
    const next = this.queue.then(async () => {
      if (!this.initialized) {
        await mkdir(dirname(this.filePath), { recursive: true });
        this.initialized = true;
      }
      const line = JSON.stringify(record) + '\n';
      await appendFile(this.filePath, line, 'utf8');
    });
    this.queue = next.catch(() => undefined);
    await next;
  }
}
