import { ext } from "./chrome.ts";
import { ApiFailure, saveItem, type SaveBody } from "./api.ts";

export const QUEUE_KEY = "queue";
export const ALARM = "sroka-retry";
export const MAX_QUEUED_HTML = 1024 * 1024; // keep storage.local small; server refetches otherwise
const MAX_ATTEMPTS = 50;

export interface QueueEntry {
  id: string;
  body: SaveBody;
  attempts: number;
  nextAt: number;
  addedAt: number;
}

export function backoffMs(attempts: number, retryAfterSec?: number): number {
  const base = Math.min(30_000 * 2 ** Math.max(0, attempts - 1), 60 * 60_000);
  return Math.max(base, (retryAfterSec ?? 0) * 1000);
}

// Serialize read-modify-write cycles within this worker instance.
let chain: Promise<unknown> = Promise.resolve();
function locked<T>(fn: () => Promise<T>): Promise<T> {
  const p = chain.then(fn, fn);
  chain = p.catch(() => undefined);
  return p;
}

export async function readQueue(): Promise<QueueEntry[]> {
  const r = await ext().storage.local.get(QUEUE_KEY);
  return Array.isArray(r[QUEUE_KEY]) ? (r[QUEUE_KEY] as QueueEntry[]) : [];
}
const writeQueue = (q: QueueEntry[]) => ext().storage.local.set({ [QUEUE_KEY]: q });

async function scheduleAlarm(q: QueueEntry[]) {
  if (!q.length) {
    await ext().alarms.clear(ALARM);
    return;
  }
  const when = Math.max(Math.min(...q.map((e) => e.nextAt)), Date.now() + 30_000);
  await ext().alarms.create(ALARM, { when });
}

export function enqueue(body: SaveBody, now = Date.now()): Promise<QueueEntry> {
  return locked(async () => {
    const q = await readQueue();
    const b = { ...body };
    if (b.html && b.html.length > MAX_QUEUED_HTML) delete b.html;
    const entry: QueueEntry = { id: crypto.randomUUID(), body: b, attempts: 0, nextAt: now, addedAt: now };
    q.push(entry);
    await writeQueue(q);
    await scheduleAlarm(q);
    return entry;
  });
}

/** Try every due entry. 401 stops processing and keeps everything. */
export function processQueue(now = Date.now()): Promise<{ sent: number; remaining: number }> {
  return locked(async () => {
    let q = await readQueue();
    let sent = 0;
    for (const e of [...q]) {
      if (e.nextAt > now) continue;
      try {
        await saveItem(e.body);
        q = q.filter((x) => x.id !== e.id);
        sent++;
      } catch (err) {
        if (!(err instanceof ApiFailure)) throw err;
        if (err.unauthorized) break; // never drop; wait for sign-in
        if (err.status === 413 && e.body.html) {
          e.body = { ...e.body };
          delete e.body.html; // fall back to URL-only save
          e.nextAt = now;
          continue;
        }
        if (err.retryable) {
          e.attempts++;
          e.nextAt = now + backoffMs(e.attempts, err.retryAfter);
          continue;
        }
        // Permanent client error (e.g. invalid_url): retrying cannot help.
        q = q.filter((x) => x.id !== e.id);
      }
    }
    q = q.filter((e) => e.attempts < MAX_ATTEMPTS);
    await writeQueue(q);
    await scheduleAlarm(q);
    return { sent, remaining: q.length };
  });
}

/** After sign-in: make everything due immediately. */
export function releaseQueue(now = Date.now()): Promise<void> {
  return locked(async () => {
    const q = (await readQueue()).map((e) => ({ ...e, nextAt: now }));
    await writeQueue(q);
  });
}
