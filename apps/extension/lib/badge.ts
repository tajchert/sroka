import { lookupUrl } from "./api.ts";
import { getCached, setCached } from "./badge-cache.ts";
import { ext } from "./chrome.ts";
import { isSavableUrl } from "./save.ts";
import { getSettings } from "./settings.ts";

/** Toolbar-icon menu entries shown only while the active tab's page is saved; handlers in `lib/item-menu.ts`. */
export const MENU_OPEN_ITEM = "open-item";
export const MENU_REMOVE_ITEM = "remove-item";

export async function paintBadge(tabId: number, saved: boolean) {
  const a = ext().action;
  await a.setBadgeText({ tabId, text: saved ? "✓" : "" });
  if (saved) {
    await a.setBadgeBackgroundColor({ tabId, color: "#1e6f8f" });
    await a.setBadgeTextColor?.({ tabId, color: "#ffffff" });
  }
  await syncItemMenu(tabId, saved);
}

/** Shows "Open in Sroka"/"Remove from Sroka" on the toolbar icon's menu while the page is saved.
 * Menus are global, so only the active tab of its window decides. */
export async function syncItemMenu(tabId: number, saved: boolean) {
  const c = ext();
  if (!c.contextMenus) return;
  try {
    if (!(await c.tabs.get(tabId)).active) return;
    await c.contextMenus.update(MENU_OPEN_ITEM, { visible: saved });
    await c.contextMenus.update(MENU_REMOVE_ITEM, { visible: saved });
  } catch {
    /* tab gone or menus not created yet */
  }
}

/** A cached ✓ older than this is re-checked: the item may have been removed elsewhere (web, Android). */
export const RECHECK_SAVED = 10_000;

/** Cached lookup → badge. Network on cache miss, and to re-check a cached ✓ (painted first); failures leave the badge as is. */
export async function refreshBadge(tabId: number, url: string | undefined, opts: { force?: boolean } = {}) {
  // A slow lookup may finish after navigation; only paint if the tab still shows this URL.
  const paintIfCurrent = async (saved: boolean) => {
    try {
      const cur = await ext().tabs?.get(tabId);
      if (cur && cur.url !== url) return;
    } catch {
      return; // tab gone
    }
    await paintBadge(tabId, saved);
  };
  try {
    if (!isSavableUrl(url)) return await paintBadge(tabId, false);
    const s = await getSettings();
    if (s.signedOut) return await paintBadge(tabId, false);
    let entry = opts.force ? null : await getCached(url);
    if (entry?.saved && Date.now() - entry.at > RECHECK_SAVED) {
      await paintIfCurrent(true);
      entry = null;
    }
    if (!entry) {
      const item = await lookupUrl(url);
      await setCached(url, { saved: !!item, id: item?.id });
      entry = { saved: !!item, id: item?.id, at: Date.now() };
    }
    await paintIfCurrent(entry.saved);
  } catch {
    /* offline or 401: leave as is */
  }
}
