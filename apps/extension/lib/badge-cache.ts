import { normalizeUrl } from "@sroka/shared";
import { ext } from "./chrome.ts";

const KEY = "badgeCache";
export const TTL_SAVED = 30 * 60_000;
export const TTL_UNSAVED = 5 * 60_000;
const MAX_ENTRIES = 300;

export interface CacheEntry {
  saved: boolean;
  id?: string;
  at: number;
}

function area() {
  return ext().storage.session ?? ext().storage.local;
}

export function cacheKey(url: string): string | null {
  try {
    return normalizeUrl(url);
  } catch {
    return null;
  }
}

async function readAll(): Promise<Record<string, CacheEntry>> {
  const r = await area().get(KEY);
  return (r[KEY] as Record<string, CacheEntry> | undefined) ?? {};
}

export async function getCached(url: string, now = Date.now()): Promise<CacheEntry | null> {
  const k = cacheKey(url);
  if (!k) return null;
  const e = (await readAll())[k];
  if (!e) return null;
  return now - e.at > (e.saved ? TTL_SAVED : TTL_UNSAVED) ? null : e;
}

export async function setCached(url: string, entry: { saved: boolean; id?: string }, now = Date.now()) {
  const k = cacheKey(url);
  if (!k) return;
  const all = await readAll();
  all[k] = { ...entry, at: now };
  const keys = Object.keys(all);
  if (keys.length > MAX_ENTRIES) {
    keys.sort((a, b) => all[a]!.at - all[b]!.at);
    for (const old of keys.slice(0, keys.length - MAX_ENTRIES)) delete all[old];
  }
  await area().set({ [KEY]: all });
}

export async function invalidate(url: string) {
  const k = cacheKey(url);
  if (!k) return;
  const all = await readAll();
  delete all[k];
  await area().set({ [KEY]: all });
}

export async function clearCache() {
  await area().remove(KEY);
}
