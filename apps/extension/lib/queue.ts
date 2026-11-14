import { log } from "@sroka/shared";
import { ext } from "./chrome.ts";
import { ApiFailure, saveItem, type SaveBody } from "./api.ts";
import { addSaved } from "./saved-set.ts";
import { getSettings, type Settings } from "./settings.ts";

export const QUEUE_KEY = "queue";
export const ALARM = "sroka-retry";
export const FAILED_KEY = "failedSaves";
export const MAX_QUEUED_HTML = 1024 * 1024; // bytes per entry; server refetches otherwise
export const MAX_QUEUED_HTML_TOTAL = 4 * 1024 * 1024; // bytes across the queue (storage.local is 10 MB)
const MAX_FAILED = 50;
/**
 * Bounds (nothing retries forever). A retryable failure gives up only when the entry is older than MAX_QUEUE_AGE
 * *and* has had at least MIN_ATTEMPTS_BEFORE_EXPIRY tries, so a browser closed for a week still gets several
 * attempts first; entries waiting for sign-in or for their own account are not attempted and never expire.
 * The queue holds at most MAX_QUEUE_LENGTH entries: a new save beyond that is refused (the user sees the failure
 * right away) rather than evicting an older one. Every drop is recorded in `failedSaves`, shown by the popup.
 */
export const MAX_QUEUE_AGE = 7 * 24 * 60 * 60_000;
export const MIN_ATTEMPTS_BEFORE_EXPIRY = 10;
export const MAX_QUEUE_LENGTH = 500;

export class QueueFullError extends Error {
  constructor() {
    super("Too many saves are waiting to be sent. Try again once you're back online.");
  }
}

const byteLen = (s: string) => new TextEncoder().encode(s).length;

export interface QueueEntry {
  id: string;
  body: SaveBody;
  attempts: number;
  nextAt: number;
  addedAt: number;
  /**
   * Who queued it: the account (email, null if signed out at the time) and server. Entries are only sent with
   * a matching session, so one person's captured pages never go to another account or another server.
   */
  owner?: { email: string | null; serverUrl: string };
}

const normEmail = (e: string | null | undefined) => (e ? e.trim().toLowerCase() : null);

/** True if `e` may be sent with the current session. Legacy entries (no owner) predate this check. */
export function ownedBy(e: QueueEntry, s: Pick<Settings, "email" | "serverUrl">): boolean {
  if (!e.owner) return true;
  if (e.owner.serverUrl !== s.serverUrl) return false;
  return e.owner.email === null || normEmail(e.owner.email) === normEmail(s.email);
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

/** Saves dropped (permanently rejected, given up after MAX_QUEUE_AGE, or refused because the queue was full);
 * kept so the popup can show them instead of dropping silently. */
export interface FailedSave {
  url: string;
  reason: string;
  at: number;
}
export async function readFailed(): Promise<FailedSave[]> {
  const r = await ext().storage.local.get(FAILED_KEY);
  return Array.isArray(r[FAILED_KEY]) ? (r[FAILED_KEY] as FailedSave[]) : [];
}
export async function clearFailed(): Promise<void> {
  await ext().storage.local.remove(FAILED_KEY);
}
async function recordFailed(url: string, reason: string, now: number) {
  try {
    const f = [...(await readFailed()), { url, reason, at: now }].slice(-MAX_FAILED);
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

async function scheduleAlarm(all: QueueEntry[]) {
  const s = await getSettings();
  const q = all.filter((e) => ownedBy(e, s));
  if (!q.length || s.signedOut) {
    await ext().alarms.clear(ALARM);
    return;
  }
  const when = Math.max(Math.min(...q.map((e) => e.nextAt)), Date.now() + 30_000);
  await ext().alarms.create(ALARM, { when });
}

export function enqueue(body: SaveBody, now = Date.now()): Promise<QueueEntry> {
  return locked(async () => {
    const q = await readQueue();
    if (q.length >= MAX_QUEUE_LENGTH) {
      await recordFailed(body.url, "queue_full", now);
      log.warn("save queue full", { event: "ext_queue_full", size: q.length });
      throw new QueueFullError();
    }
    const b = { ...body };
    if (b.html) {
      const size = byteLen(b.html);
      const used = q.reduce((n, e) => n + (e.body.html ? byteLen(e.body.html) : 0), 0);
      if (size > MAX_QUEUED_HTML || used + size > MAX_QUEUED_HTML_TOTAL) delete b.html;
    }
    const s = await getSettings();
    const owner = { email: s.signedOut ? null : normEmail(s.email), serverUrl: s.serverUrl };
    const entry: QueueEntry = { id: crypto.randomUUID(), body: b, attempts: 0, nextAt: now, addedAt: now, owner };
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
    const s = await getSettings();
    if (s.signedOut) {
      await ext().alarms.clear(ALARM);
      return { sent: 0, remaining: q.length };
    }
    let sent = 0;
    for (const e of [...q]) {
      if (e.nextAt > now) continue;
      if (!ownedBy(e, s)) continue; // another account's / server's saves wait for their own session
      try {
        const r = await saveItem(e.body);
        await addSaved(r.item).catch(() => undefined);
        q = q.filter((x) => x.id !== e.id);
        sent++;
      } catch (err) {
        // Anything unexpected (a bug, a storage error) is handled like a network failure: the entry backs off,
        // and the pass goes on so the queue is still written and the alarm re-armed below.
        const failure = err instanceof ApiFailure ? err : new ApiFailure(0, "unexpected");
        if (!(err instanceof ApiFailure)) {
          log.warn("queued save failed unexpectedly", { event: "ext_queue_unexpected", name: err instanceof Error ? err.name : "unknown" });
        }
        if (failure.unauthorized) break; // never drop; wait for sign-in
        if (failure.status === 413 && e.body.html) {
          e.body = { ...e.body };
          delete e.body.html; // fall back to URL-only save
          e.nextAt = now;
          continue;
        }
        if (failure.status === 400 && failure.code !== "invalid_url" && e.body.title) {
          e.body = { ...e.body };
          delete e.body.title; // e.g. title rejected: retry without it
          e.nextAt = now;
          continue;
        }
        if (failure.retryable) {
          e.attempts++;
          if (now - e.addedAt > MAX_QUEUE_AGE && e.attempts >= MIN_ATTEMPTS_BEFORE_EXPIRY) {
            q = q.filter((x) => x.id !== e.id);
            await recordFailed(e.body.url, "expired", now);
            log.warn("queued save given up", { event: "ext_queue_expired", attempts: e.attempts, status: failure.status });
            continue;
          }
          e.nextAt = now + backoffMs(e.attempts, failure.retryAfter);
          continue;
        }
        // Permanent client error (e.g. invalid_url): retrying cannot help.
        q = q.filter((x) => x.id !== e.id);
        await recordFailed(e.body.url, failure.code, now);
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
