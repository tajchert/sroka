import { Item, log, PullResponse, tryNormalizeUrl, urlHash } from "@sroka/shared";
import { ApiFailure, rawFetch } from "./api.ts";
import { ext } from "./chrome.ts";
import { getSettings, type Settings } from "./settings.ts";

/**
 * Local set of the user's saved URLs, so the toolbar badge is decided without sending visited URLs anywhere (D8).
 *
 * Each live item contributes the hash of its normalized URL(s) (`canonicalUrl` and `normalizeUrl(url)`, the same
 * form the server dedupes on, api.md §13): the first HASH_LEN hex chars of sha256 — 48 bits, so a false ✓ needs a
 * collision (~1e-10 per page view for 50k items). Stored in storage.local, sharded by the first two hex chars into
 * 256 keys `savedSet.<xx>` = `{ [hash]: itemId without dashes }` (~50 bytes per item; 50k items ≈ 2.5 MB), plus
 * `savedSet.meta` (owner, sync cursor). A tab event reads one small shard; a save/delete rewrites one shard.
 *
 * Filled from `GET /v1/sync/pull` (api.md §7.2): a full pass from 0 the first time (and after `410
 * resync_required`), then incremental from the stored cursor; `deleted.items` tombstones remove entries.
 */

export const META_KEY = "savedSet.meta";
export const SHARD_PREFIX = "savedSet.";
export const REFRESH_ALARM = "sroka-saved-set";
export const REFRESH_MINUTES = 20;
export const HASH_LEN = 12;
export const PULL_LIMIT = 1000;
const SHARD_KEYS = Array.from({ length: 256 }, (_, i) => SHARD_PREFIX + i.toString(16).padStart(2, "0"));

type Shard = Record<string, string>;
type Owner = { email: string | null; serverUrl: string };
interface Meta {
  v: 1;
  owner: Owner;
  cursor: number;
  loadedAt: number;
}

/** Only the fields the set needs; extra fields (title, tags…) are stripped, so the pull stays tolerant. */
const PullIds = PullResponse.pick({ cursor: true, hasMore: true, deleted: true }).extend({
  items: Item.pick({ id: true, url: true, canonicalUrl: true }).array(),
});
type ItemRef = { id: string; url?: string | null; canonicalUrl?: string | null };

const ownerOf = (s: Pick<Settings, "email" | "serverUrl">): Owner => ({
  email: s.email ? s.email.trim().toLowerCase() : null,
  serverUrl: s.serverUrl,
});
const sameOwner = (a: Owner, b: Owner) => a.email === b.email && a.serverUrl === b.serverUrl;
const shardKey = (hash: string) => SHARD_PREFIX + hash.slice(0, 2);
const packId = (id: string) => id.replace(/-/g, "");
const unpackId = (p: string) =>
  p.length === 32 ? `${p.slice(0, 8)}-${p.slice(8, 12)}-${p.slice(12, 16)}-${p.slice(16, 20)}-${p.slice(20)}` : p;

/** Compact hash of a URL's normalized form, or null when it does not normalize (non-http, garbage). */
export async function savedUrlHash(url: string): Promise<string | null> {
  const canonical = tryNormalizeUrl(url);
  return canonical ? (await urlHash(canonical)).slice(0, HASH_LEN) : null;
}

async function hashesOf(urls: Array<string | null | undefined>): Promise<string[]> {
  const out = new Set<string>();
  for (const u of urls) {
    const h = u ? await savedUrlHash(u) : null;
    if (h) out.add(h);
  }
  return [...out];
}

const area = () => ext().storage.local;

async function readMeta(): Promise<Meta | null> {
  const m = (await area().get(META_KEY))[META_KEY] as Meta | undefined;
  return m && m.v === 1 ? m : null;
}

/** Meta if the set is loaded and belongs to the current session, else null. */
async function currentMeta(): Promise<Meta | null> {
  const s = await getSettings();
  if (s.signedOut) return null;
  const m = await readMeta();
  return m && sameOwner(m.owner, ownerOf(s)) ? m : null;
}

async function readShards(keys: string[]): Promise<Record<string, Shard>> {
  const r = await area().get(keys);
  return Object.fromEntries(keys.map((k) => [k, (r[k] as Shard | undefined) ?? {}]));
}

// Serialize read-modify-write cycles within this context (background worker / popup).
let chain: Promise<unknown> = Promise.resolve();
function locked<T>(fn: () => Promise<T>): Promise<T> {
  const p = chain.then(fn, fn);
  chain = p.catch(() => undefined);
  return p;
}

/**
 * Local badge lookup, no network. `null` = the set was never loaded for this session (first run, offline,
 * signed out): callers show no badge. Otherwise whether the URL is saved, with the item id.
 */
export async function lookupSaved(url: string): Promise<{ saved: boolean; id?: string } | null> {
  if (!(await currentMeta())) return null;
  const h = await savedUrlHash(url);
  if (!h) return { saved: false };
  const k = shardKey(h);
  const id = ((await area().get(k))[k] as Shard | undefined)?.[h];
  return id ? { saved: true, id: unpackId(id) } : { saved: false };
}

/** The extension saved an item: add it to the loaded set (one shard write). No-op when the set isn't loaded. */
export function addSaved(item: ItemRef): Promise<void> {
  return locked(async () => {
    if (!(await currentMeta())) return;
    const hs = await hashesOf([item.canonicalUrl, item.url]);
    if (!hs.length) return;
    const shards = await readShards([...new Set(hs.map(shardKey))]);
    for (const h of hs) shards[shardKey(h)]![h] = packId(item.id);
    await area().set(shards);
  });
}

/** The extension deleted an item: drop its entries under the given URLs (tab URL, item url/canonicalUrl). */
export function removeSaved(id: string, urls: Array<string | null | undefined>): Promise<void> {
  return locked(async () => {
    if (!(await currentMeta())) return;
    const hs = await hashesOf(urls);
    if (!hs.length) return;
    const p = packId(id);
    const shards = await readShards([...new Set(hs.map(shardKey))]);
    for (const h of hs) if (shards[shardKey(h)]![h] === p) delete shards[shardKey(h)]![h];
    await area().set(shards);
  });
}

/** Sign-out / account or server change: forget everything. */
export async function clearSavedSet(): Promise<void> {
  await area().remove([META_KEY, ...SHARD_KEYS]);
}

async function pullPage(cursor: number, full: boolean) {
  const res = await rawFetch(`/v1/sync/pull?cursor=${cursor}&limit=${PULL_LIMIT}${full ? "&full=1" : ""}`);
  return PullIds.parse(await res.json());
}

/** Full pass from 0 into memory; replaces the stored set only when the pass completes. */
async function fullPass(owner: Owner, now: number): Promise<number> {
  const byId = new Map<string, string[]>();
  let cursor = 0;
  for (;;) {
    const page = await pullPage(cursor, true);
    for (const it of page.items) byId.set(it.id, await hashesOf([it.canonicalUrl, it.url]));
    for (const id of page.deleted.items) byId.delete(id);
    cursor = page.cursor;
    if (!page.hasMore) break;
  }
  const shards: Record<string, Shard> = Object.fromEntries(SHARD_KEYS.map((k) => [k, {}]));
  for (const [id, hs] of byId) for (const h of hs) shards[shardKey(h)]![h] = packId(id);
  const meta: Meta = { v: 1, owner, cursor, loadedAt: now };
  await area().set({ ...shards, [META_KEY]: meta });
  return byId.size;
}

/** Incremental pull from the stored cursor; rewrites only the shards that changed. */
async function incremental(meta: Meta, now: number): Promise<void> {
  const upserts = new Map<string, string[]>();
  const deleted = new Set<string>();
  let cursor = meta.cursor;
  for (;;) {
    const page = await pullPage(cursor, false);
    for (const it of page.items) {
      deleted.delete(it.id);
      upserts.set(it.id, await hashesOf([it.canonicalUrl, it.url]));
    }
    for (const id of page.deleted.items) {
      upserts.delete(id);
      deleted.add(id);
    }
    cursor = page.cursor;
    if (!page.hasMore) break;
  }
  const writes: Record<string, unknown> = {};
  if (upserts.size || deleted.size) {
    // Tombstones carry only ids, so a deletion needs every shard; upserts only touch their own.
    const keys = deleted.size ? SHARD_KEYS : [...new Set([...upserts.values()].flat().map(shardKey))];
    const shards = await readShards(keys);
    const dirty = new Set<string>();
    if (deleted.size) {
      const gone = new Set([...deleted].map(packId));
      for (const [k, shard] of Object.entries(shards))
        for (const [h, id] of Object.entries(shard))
          if (gone.has(id)) {
            delete shard[h];
            dirty.add(k);
          }
    }
    for (const [id, hs] of upserts)
      for (const h of hs) {
        shards[shardKey(h)]![h] = packId(id);
        dirty.add(shardKey(h));
      }
    for (const k of dirty) writes[k] = shards[k];
  }
  writes[META_KEY] = { ...meta, cursor, loadedAt: now } satisfies Meta;
  await area().set(writes);
}

let inFlight: Promise<boolean> | null = null;

/**
 * Bring the set up to date (sign-in, browser startup, periodic alarm). Coalesces concurrent calls.
 * Resolves true when the set is loaded and current; false when signed out or the refresh failed (the old set,
 * if any, is kept).
 */
export function refreshSavedSet(now = Date.now()): Promise<boolean> {
  inFlight ??= locked(async () => {
    const s = await getSettings();
    if (s.signedOut) return false;
    const owner = ownerOf(s);
    const prev = await readMeta();
    try {
      if (prev && sameOwner(prev.owner, owner)) {
        try {
          await incremental(prev, now);
          return true;
        } catch (e) {
          if (!(e instanceof ApiFailure && e.status === 410)) throw e;
          log.info("saved set resync", { event: "ext_saved_set_resync" });
        }
      } else if (prev) {
        await clearSavedSet(); // another account or server
      }
      const n = await fullPass(owner, now);
      log.info("saved set loaded", { event: "ext_saved_set_loaded", items: n });
      return true;
    } catch (e) {
      log.warnException("saved set refresh failed", e, { event: "ext_saved_set_refresh_failed" });
      return false;
    }
  }).finally(() => {
    inFlight = null;
  });
  return inFlight;
}

/** Periodic refresh; idempotent (re-creating keeps one alarm). */
export async function scheduleSavedSetRefresh(): Promise<void> {
  await ext().alarms.create(REFRESH_ALARM, { periodInMinutes: REFRESH_MINUTES });
}
