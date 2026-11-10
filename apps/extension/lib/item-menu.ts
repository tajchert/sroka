import { deleteItem, lookupUrl } from "./api.ts";
import { paintBadge } from "./badge.ts";
import { openApp } from "./open-app.ts";
import { lookupSaved, removeSaved } from "./saved-set.ts";

export { MENU_OPEN_ITEM, MENU_REMOVE_ITEM } from "./badge.ts";

/**
 * Saved item id for this URL: the local saved set first; otherwise a server lookup. The lookup sends the URL,
 * which is fine here: it only runs after the user picked "Open in Sroka"/"Remove from Sroka" on this page.
 */
async function savedItemId(url: string): Promise<string | null> {
  const local = await lookupSaved(url);
  if (local?.saved && local.id) return local.id;
  const item = await lookupUrl(url);
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
    if (id) {
      await deleteItem(id);
      await removeSaved(id, [url]);
    }
    await paintBadge(tabId, false);
  } catch {
    await chrome.action.setBadgeText({ tabId, text: "!" });
    await chrome.action.setBadgeBackgroundColor({ tabId, color: "#b91c1c" });
  }
}
