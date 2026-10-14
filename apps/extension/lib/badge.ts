import { lookupUrl } from "./api.ts";
import { getCached, setCached } from "./badge-cache.ts";
import { ext } from "./chrome.ts";
import { isSavableUrl } from "./save.ts";
import { getSettings } from "./settings.ts";

export async function paintBadge(tabId: number, saved: boolean) {
  const a = ext().action;
  await a.setBadgeText({ tabId, text: saved ? "✓" : "" });
  if (saved) {
    await a.setBadgeBackgroundColor({ tabId, color: "#0f766e" });
    await a.setBadgeTextColor?.({ tabId, color: "#ffffff" });
  }
}

/** Cached lookup → badge. Network only on cache miss; failures leave badge blank. */
export async function refreshBadge(tabId: number, url: string | undefined, opts: { force?: boolean } = {}) {
  try {
    if (!isSavableUrl(url)) return await paintBadge(tabId, false);
    const s = await getSettings();
    if (s.signedOut) return await paintBadge(tabId, false);
    let entry = opts.force ? null : await getCached(url);
    if (!entry) {
      const item = await lookupUrl(url);
      await setCached(url, { saved: !!item, id: item?.id });
      entry = { saved: !!item, id: item?.id, at: Date.now() };
    }
    // A slow lookup may finish after navigation; only paint if the tab still shows this URL.
    try {
      const cur = await ext().tabs?.get(tabId);
      if (cur && cur.url !== url) return;
    } catch {
      return; // tab gone
    }
    await paintBadge(tabId, entry.saved);
  } catch {
    /* offline or 401: leave as is */
  }
}
