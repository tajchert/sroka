import { ext } from "./chrome.ts";
import { ApiFailure, saveItem, type SaveBody } from "./api.ts";
import { getSettings } from "./settings.ts";

export const QUEUE_KEY = "queue";
export const ALARM = "sroka-retry";
export const FAILED_KEY = "failedSaves";
export const MAX_QUEUED_HTML = 1024 * 1024; // bytes per entry; server refetches otherwise
export const MAX_QUEUED_HTML_TOTAL = 4 * 1024 * 1024; // bytes across the queue (storage.local is 10 MB)
const MAX_FAILED = 50;

const byteLen = (s: string) => new TextEncoder().encode(s).length;

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

/** Saves the server permanently rejected; kept so the UI can show them instead of dropping silently. */
export interface FailedSave {
  url: string;
  reason: string;
  at: number;
}
export async function readFailed(): Promise<FailedSave[]> {
  const r = await ext().storage.local.get(FAILED_KEY);
  return Array.isArray(r[FAILED_KEY]) ? (r[FAILED_KEY] as FailedSave[]) : [];
}
async function recordFailed(e: QueueEntry, reason: string, now: number) {
  try {
    const f = [...(await readFailed()), { url: e.body.url, reason, at: now }].slice(-MAX_FAILED);
    await ext().storage.local.set({ [FAILED_KEY]: f });
  } catch {
    /* best effort */
  }
}

function stripHtml(q: QueueEntry[]): QueueEntry[] {
  return q.map((e) => {
    if (!e.body.html) return e;
    const body = { ...e.body };
    delete body.html;
    return { ...e, body };
  });
}

/** Write the queue; on quota failure drop captured html (server refetches) and retry. */
async function writeQueue(q: QueueEntry[]): Promise<QueueEntry[]> {
  try {
    await ext().storage.local.set({ [QUEUE_KEY]: q });
    return q;
  } catch {
    const slim = stripHtml(q);
    await ext().storage.local.set({ [QUEUE_KEY]: slim });
    return slim;
  }
}

async function scheduleAlarm(q: QueueEntry[]) {
  if (!q.length || (await getSettings()).signedOut) {
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
    if (b.html) {
      const size = byteLen(b.html);
      const used = q.reduce((n, e) => n + (e.body.html ? byteLen(e.body.html) : 0), 0);
      if (size > MAX_QUEUED_HTML || used + size > MAX_QUEUED_HTML_TOTAL) delete b.html;
    }
    const entry: QueueEntry = { id: crypto.randomUUID(), body: b, attempts: 0, nextAt: now, addedAt: now };
    q.push(entry);
    const written = await writeQueue(q);
    await scheduleAlarm(written);
    return entry;
  });
}

/** Try every due entry. 401 stops processing and keeps everything. */
export function processQueue(now = Date.now()): Promise<{ sent: number; remaining: number }> {
  return locked(async () => {
    let q = await readQueue();
    if ((await getSettings()).signedOut) {
      await ext().alarms.clear(ALARM);
      return { sent: 0, remaining: q.length };
    }
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
        if (err.status === 400 && err.code !== "invalid_url" && e.body.title) {
          e.body = { ...e.body };
          delete e.body.title; // e.g. title rejected: retry without it
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
        await recordFailed(e, err.code, now);
      }
    }
    q = await writeQueue(q);
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

/** Remove queued saves for a URL (caller is about to save it directly). */
export function removeQueuedUrl(url: string): Promise<void> {
  return locked(async () => {
    const q = await readQueue();
    const next = q.filter((e) => e.body.url !== url);
    if (next.length !== q.length) await writeQueue(next);
  });
}
