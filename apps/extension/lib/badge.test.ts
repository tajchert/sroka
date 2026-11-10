import { beforeEach, describe, expect, it, vi } from "vitest";
import { refreshBadge } from "./badge.ts";
import { setSettings } from "./settings.ts";
import { installChrome, loadSavedSet } from "./test-chrome.ts";

const I1 = "01929b1e-6f1c-7a2b-9c3d-4e5f60718293";
let c: ReturnType<typeof installChrome>;
beforeEach(async () => {
  c = installChrome();
  vi.restoreAllMocks();
  await setSettings({ token: "t", email: "a@b.c", signedOut: false });
});

describe("refreshBadge (local saved set, no network)", () => {
  it("paints ✓ for a saved URL in any equivalent form and clears it for others, without a request", async () => {
    await loadSavedSet([{ id: I1, url: "https://a.com/x?utm_source=n&b=2&a=1" }]);
    const f = vi.spyOn(globalThis, "fetch");
    await refreshBadge(5, "HTTPS://A.com:443/x?a=1&b=2#top");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 5, text: "✓" });
    await refreshBadge(5, "https://a.com/other");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 5, text: "" });
    await refreshBadge(5, "https://a.com/x/"); // trailing slash is a different URL (api.md §13)
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 5, text: "" });
    expect(f).not.toHaveBeenCalled();
  });

  it("shows no badge and makes no request while the set was never loaded", async () => {
    const f = vi.spyOn(globalThis, "fetch");
    await refreshBadge(1, "https://a.com/x");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 1, text: "" });
    expect(f).not.toHaveBeenCalled();
  });

  it("clears the badge for restricted urls and when signed out", async () => {
    await loadSavedSet([{ id: I1, url: "https://a.com/x" }]);
    await refreshBadge(2, "chrome://extensions");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 2, text: "" });
    await setSettings({ signedOut: true });
    await refreshBadge(3, "https://a.com/x");
    expect(c.action.setBadgeText).toHaveBeenLastCalledWith({ tabId: 3, text: "" });
  });

  it("does not paint when the tab navigated away meanwhile", async () => {
    await loadSavedSet([{ id: I1, url: "https://a.com/x" }]);
    Object.assign(c, { tabs: { get: vi.fn(async () => ({ url: "https://b.com/" })) } });
    await refreshBadge(4, "https://a.com/x");
    expect(c.action.setBadgeText).not.toHaveBeenCalled();
  });
});
