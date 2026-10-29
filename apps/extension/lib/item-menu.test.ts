import { beforeEach, describe, expect, it, vi } from "vitest";
import { paintBadge } from "./badge.ts";
import { getCached, setCached } from "./badge-cache.ts";
import { MENU_OPEN_ITEM, MENU_REMOVE_ITEM, openSavedItem, removeSavedItem } from "./item-menu.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes } from "./test-chrome.ts";

type Mock = ReturnType<typeof vi.fn>;
let c: ReturnType<typeof installChrome> & {
  tabs: { get: Mock; create: Mock };
  contextMenus: { update: Mock };
};
let active = true;

beforeEach(async () => {
  active = true;
  c = Object.assign(installChrome(), {
    tabs: { get: vi.fn(async (id: number) => ({ id, active })), create: vi.fn(async () => ({})) },
    contextMenus: { update: vi.fn(async () => {}) },
  });
  vi.restoreAllMocks();
  await setSettings({ token: "t", signedOut: false });
});

describe("syncItemMenu (via paintBadge)", () => {
  it("shows the entries for a saved active tab and hides them otherwise", async () => {
    await paintBadge(1, true);
    expect(c.contextMenus.update).toHaveBeenCalledWith(MENU_OPEN_ITEM, { visible: true });
    expect(c.contextMenus.update).toHaveBeenCalledWith(MENU_REMOVE_ITEM, { visible: true });
    await paintBadge(1, false);
    expect(c.contextMenus.update).toHaveBeenLastCalledWith(MENU_REMOVE_ITEM, { visible: false });
  });

  it("ignores background tabs", async () => {
    active = false;
    await paintBadge(2, true);
    expect(c.contextMenus.update).not.toHaveBeenCalled();
  });
});

describe("openSavedItem", () => {
  it("opens the reader for the cached item without a lookup", async () => {
    await setCached("https://a.com/x", { saved: true, id: "i1" });
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(200, { appOrigin: "https://web.example" }));
    await openSavedItem("https://a.com/x");
    expect(c.tabs.create).toHaveBeenCalledWith({ url: "https://web.example/app/item/i1" });
    expect(f).toHaveBeenCalledTimes(1); // only /v1/config
  });

  it("looks the item up on a cache miss", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (u) =>
      String(u).includes("/v1/items?")
        ? jsonRes(200, { items: [{ id: "i2" }], nextCursor: null })
        : jsonRes(200, { appOrigin: "https://web.example" }),
    );
    await openSavedItem("https://a.com/y");
    expect(c.tabs.create).toHaveBeenCalledWith({ url: "https://web.example/app/item/i2" });
  });
});

describe("removeSavedItem", () => {
  it("deletes the item, marks the url unsaved and clears the badge", async () => {
    await setCached("https://a.com/x", { saved: true, id: "i1" });
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 204 }));
    await removeSavedItem(3, "https://a.com/x");
    expect(f).toHaveBeenCalledWith(expect.stringContaining("/v1/items/i1"), expect.objectContaining({ method: "DELETE" }));
    expect(await getCached("https://a.com/x")).toMatchObject({ saved: false });
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 3, text: "" });
    expect(c.contextMenus.update).toHaveBeenLastCalledWith(MENU_REMOVE_ITEM, { visible: false });
  });

  it("shows ! when the delete fails", async () => {
    await setCached("https://a.com/x", { saved: true, id: "i1" });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(500, { error: "internal" }));
    await removeSavedItem(3, "https://a.com/x");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 3, text: "!" });
    expect(await getCached("https://a.com/x")).toMatchObject({ saved: true });
  });
});
