import { beforeEach, describe, expect, it, vi } from "vitest";
import { paintBadge } from "./badge.ts";
import { MENU_OPEN_ITEM, MENU_REMOVE_ITEM, openSavedItem, removeSavedItem } from "./item-menu.ts";
import { lookupSaved } from "./saved-set.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes, loadSavedSet } from "./test-chrome.ts";

type Mock = ReturnType<typeof vi.fn>;
let c: ReturnType<typeof installChrome> & {
  tabs: { get: Mock; create: Mock };
  contextMenus: { update: Mock };
};
let active = true;
const I1 = "01929b1e-6f1c-7a2b-9c3d-4e5f60718293";

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
  it("opens the reader for an item in the local saved set without a lookup", async () => {
    await loadSavedSet([{ id: I1, url: "https://a.com/x" }]);
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(200, { appOrigin: "https://web.example" }));
    await openSavedItem("https://a.com/x");
    expect(c.tabs.create).toHaveBeenCalledWith({ url: `https://web.example/app/item/${I1}` });
    expect(f).toHaveBeenCalledTimes(1); // only /v1/config
  });

  it("looks the item up (user action) when it is not in the local set", async () => {
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
  it("deletes the item, removes it from the local set and clears the badge", async () => {
    await loadSavedSet([{ id: I1, url: "https://a.com/x" }]);
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 204 }));
    await removeSavedItem(3, "https://a.com/x");
    expect(f).toHaveBeenCalledWith(expect.stringContaining(`/v1/items/${I1}`), expect.objectContaining({ method: "DELETE" }));
    expect(await lookupSaved("https://a.com/x")).toEqual({ saved: false });
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 3, text: "" });
    expect(c.contextMenus.update).toHaveBeenLastCalledWith(MENU_REMOVE_ITEM, { visible: false });
  });

  it("shows ! when the delete fails", async () => {
    await loadSavedSet([{ id: I1, url: "https://a.com/x" }]);
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(500, { error: "internal" }));
    await removeSavedItem(3, "https://a.com/x");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 3, text: "!" });
    expect(await lookupSaved("https://a.com/x")).toEqual({ saved: true, id: I1 });
  });
});
