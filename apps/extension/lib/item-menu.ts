import { deleteItem, lookupUrl } from "./api.ts";
import { paintBadge } from "./badge.ts";
import { getCached, setCached } from "./badge-cache.ts";
import { openApp } from "./open-app.ts";

export { MENU_OPEN_ITEM, MENU_REMOVE_ITEM } from "./badge.ts";

/** Saved item id for this URL: badge cache first, then a lookup (which refreshes the cache). */
async function savedItemId(url: string): Promise<string | null> {
  const e = await getCached(url);
  if (e?.saved && e.id) return e.id;
  const item = await lookupUrl(url);
  await setCached(url, { saved: !!item, id: item?.id });
  return item?.id ?? null;
}

/** "Open in Sroka": the item's reader page, or the library if the page turns out not to be saved. */
export async function openSavedItem(url: string): Promise<void> {
  const id = await savedItemId(url).catch(() => null);
  await openApp(id ? `item/${id}` : "");
}

/** "Remove from Sroka": deletes the item and clears the badge; a failure shows "!". */
export async function removeSavedItem(tabId: number, url: string): Promise<void> {
  try {
    const id = await savedItemId(url);
    if (id) await deleteItem(id);
    await setCached(url, { saved: false });
    await paintBadge(tabId, false);
  } catch {
    await chrome.action.setBadgeText({ tabId, text: "!" });
    await chrome.action.setBadgeBackgroundColor({ tabId, color: "#b91c1c" });
  }
}
