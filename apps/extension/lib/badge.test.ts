import { beforeEach, describe, expect, it, vi } from "vitest";
import { RECHECK_SAVED, refreshBadge } from "./badge.ts";
import { getCached, invalidate, setCached, TTL_SAVED, TTL_UNSAVED } from "./badge-cache.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes } from "./test-chrome.ts";

let c: ReturnType<typeof installChrome>;
beforeEach(async () => {
  c = installChrome();
  vi.restoreAllMocks();
  await setSettings({ token: "t", signedOut: false });
});

describe("badge cache", () => {
  it("keys by normalized url and expires by ttl", async () => {
    await setCached("https://A.com/p?utm_source=x#frag", { saved: true, id: "1" }, 1000);
    expect(await getCached("https://a.com/p", 1000 + TTL_SAVED - 1)).toMatchObject({ saved: true, id: "1" });
    expect(await getCached("https://a.com/p", 1000 + TTL_SAVED + 1)).toBeNull();
    await setCached("https://b.com/", { saved: false }, 0);
    expect(await getCached("https://b.com/", TTL_UNSAVED + 1)).toBeNull();
  });

  it("invalidate removes entry; non-http urls ignored", async () => {
    await setCached("https://a.com/", { saved: true });
    await invalidate("https://a.com/");
    expect(await getCached("https://a.com/")).toBeNull();
    await setCached("chrome://settings", { saved: true });
    expect(await getCached("chrome://settings")).toBeNull();
  });
});

describe("refreshBadge", () => {
  const item = { id: "i1" };
  it("looks up on miss, paints ✓, then uses cache", async () => {
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(200, { items: [item], nextCursor: null }));
    await refreshBadge(5, "https://a.com/x");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 5, text: "✓" });
    await refreshBadge(5, "https://a.com/x");
    expect(f).toHaveBeenCalledTimes(1);
    await refreshBadge(5, "https://a.com/x", { force: true });
    expect(f).toHaveBeenCalledTimes(2);
  });

  it("re-checks a cached ✓ after RECHECK_SAVED and clears it when the item was removed elsewhere", async () => {
    await setCached("https://a.com/r", { saved: true, id: "i1" }, Date.now() - RECHECK_SAVED - 1);
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(200, { items: [], nextCursor: null }));
    await refreshBadge(6, "https://a.com/r");
    expect(f).toHaveBeenCalledTimes(1);
    expect(c.action.setBadgeText).toHaveBeenNthCalledWith(1, { tabId: 6, text: "✓" });
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 6, text: "" });
    expect(await getCached("https://a.com/r")).toMatchObject({ saved: false });
  });

  it("clears badge when not saved, for restricted urls, and when signed out", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(200, { items: [], nextCursor: null }));
    await refreshBadge(1, "https://a.com/");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 1, text: "" });
    await refreshBadge(2, "chrome://extensions");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 2, text: "" });
    await setSettings({ signedOut: true });
    const f = vi.spyOn(globalThis, "fetch");
    f.mockClear();
    await refreshBadge(3, "https://z.com/");
    expect(f).not.toHaveBeenCalled();
  });

  it("swallows network errors", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("x"));
    await expect(refreshBadge(1, "https://a.com/")).resolves.toBeUndefined();
  });
});
