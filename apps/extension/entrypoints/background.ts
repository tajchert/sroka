import { refreshBadge, paintBadge } from "../lib/badge.ts";
import type { Msg } from "../lib/messages.ts";
import { ALARM, processQueue, releaseQueue, removeQueuedUrl } from "../lib/queue.ts";
import { saveLink, saveTab, type SaveResult } from "../lib/save.ts";

async function flash(tabId: number | undefined, r: SaveResult) {
  if (tabId == null) return;
  if (r.ok) return paintBadge(tabId, true);
  if (r.queued) {
    await chrome.action.setBadgeText({ tabId, text: "…" });
    await chrome.action.setBadgeBackgroundColor({ tabId, color: "#52525b" });
  } else {
    await chrome.action.setBadgeText({ tabId, text: "!" });
    await chrome.action.setBadgeBackgroundColor({ tabId, color: "#b91c1c" });
  }
}

export default defineBackground(() => {
  chrome.runtime.onInstalled.addListener(() => {
    chrome.contextMenus.removeAll(() => {
      chrome.contextMenus.create({ id: "save-link", title: "Save link to Sroka", contexts: ["link"] });
      chrome.contextMenus.create({ id: "save-page", title: "Save page to Sroka", contexts: ["page"] });
    });
  });

  chrome.contextMenus.onClicked.addListener(async (info, tab) => {
    if (info.menuItemId === "save-link" && info.linkUrl) {
      const r = await saveLink(info.linkUrl);
      // Link isn't the current tab's page; only badge the tab when it is the same URL.
      if (tab?.id != null && tab.url === info.linkUrl) await flash(tab.id, r);
    } else if (info.menuItemId === "save-page" && tab) {
      await flash(tab.id, await saveTab(tab));
    }
  });

  chrome.commands.onCommand.addListener(async (cmd) => {
    if (cmd !== "save-page") return;
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab) await flash(tab.id, await saveTab(tab));
  });

  chrome.tabs.onActivated.addListener(async ({ tabId }) => {
    try {
      const tab = await chrome.tabs.get(tabId);
      await refreshBadge(tabId, tab.url);
    } catch {
      /* tab gone */
    }
  });
  chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
    if (change.status === "loading" || change.status === "complete" || change.url) void refreshBadge(tabId, change.url ?? tab.url);
  });

  chrome.alarms.onAlarm.addListener((a) => {
    if (a.name === ALARM) void processQueue();
  });
  chrome.runtime.onStartup.addListener(() => void processQueue());

  chrome.runtime.onMessage.addListener((msg: Msg, _sender, sendResponse) => {
    const fail = (e: unknown) => sendResponse({ ok: false, queued: false, reason: "error", message: String(e) });
    if (msg.type === "save-tab") {
      saveTab(msg.tab)
        .then(async (r) => {
          await flash(msg.tab.id, r).catch(() => undefined);
          sendResponse(r);
        })
        .catch(fail);
      return true;
    }
    if (msg.type === "refresh-badge") {
      refreshBadge(msg.tabId, msg.url, { force: false }).then(() => sendResponse(true), () => sendResponse(false));
      return true;
    }
    if (msg.type === "process-queue") {
      processQueue().then(sendResponse, () => sendResponse({ sent: 0, remaining: -1 }));
      return true;
    }
    if (msg.type === "release-queue") {
      (msg.skipUrl ? removeQueuedUrl(msg.skipUrl) : Promise.resolve())
        .then(() => releaseQueue())
        .then(() => processQueue())
        .then(sendResponse, () => sendResponse({ sent: 0, remaining: -1 }));
      return true;
    }
    return false;
  });
});
