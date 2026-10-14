import { buildContentBaseUrl, contentScope, defaultExp, type Item } from "@sroka/shared";
import type { ItemData } from "./rows.ts";

export interface SignEnv {
  CONTENT_ORIGIN: string;
  CONTENT_URL_SIGNING_KEY: string;
}

/** Adds a freshly signed `leadImageUrl` (api.md §4.1) to each item. One expiry for the whole batch. */
export async function withLeadImageUrls(env: SignEnv, userId: string, items: ItemData[], now = Date.now()): Promise<Item[]> {
  const exp = defaultExp(now);
  const cache = new Map<string, string>();
  const out: Item[] = [];
  for (const it of items) {
    let leadImageUrl: string | null = null;
    if (it.contentId && it.leadImageKey) {
      const scope = contentScope(it.contentPrivate, userId);
      const cacheKey = `${scope}/${it.contentId}`;
      let base = cache.get(cacheKey);
      if (!base) {
        base = (
          await buildContentBaseUrl({
            origin: env.CONTENT_ORIGIN,
            secret: env.CONTENT_URL_SIGNING_KEY,
            scope,
            contentId: it.contentId,
            exp,
          })
        ).baseUrl;
        cache.set(cacheKey, base);
      }
      leadImageUrl = base + it.leadImageKey;
    }
    out.push({ ...it, leadImageUrl });
  }
  return out;
}
