import { ext } from "./chrome.ts";
import { isSavableUrl } from "./save.ts";
import { lookupSaved } from "./saved-set.ts";
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

/**
 * Badge from the local saved-URL set only (`lib/saved-set.ts`): browsing never sends the visited URL anywhere (D8).
 * Set not loaded yet (first run, offline) → no badge.
 */
export async function refreshBadge(tabId: number, url: string | undefined) {
  try {
    if (!isSavableUrl(url)) return await paintBadge(tabId, false);
    const s = await getSettings();
    if (s.signedOut) return await paintBadge(tabId, false);
    const r = await lookupSaved(url);
    // The tab may have navigated meanwhile; only paint if it still shows this URL.
    try {
      const cur = await ext().tabs?.get(tabId);
      if (cur && cur.url !== url) return;
    } catch {
      return; // tab gone
    }
    await paintBadge(tabId, !!r?.saved);
  } catch {
    /* storage unavailable: leave as is */
  }
}
