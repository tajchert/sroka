import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { trackEvent } from "./analytics.ts";
import { autoCloseWanted } from "./auto-close.ts";
import { consentCardDue, consentCardVisible, HAS_SAVED_KEY, hasSavedOnce, setConsent } from "./consent.ts";
import { saveTab } from "./save.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes } from "./test-chrome.ts";

const CFG = { measurementId: "G-TEST", apiSecret: "sekret" };
let c: ReturnType<typeof installChrome>;
let fetchMock: ReturnType<typeof vi.fn<typeof globalThis.fetch>>;

beforeEach(async () => {
  c = installChrome();
  fetchMock = vi.fn<typeof globalThis.fetch>(async () => jsonRes(201, { item: { id: "i1", url: "https://a.example/x" }, created: true }));
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("__SROKA_GA__", CFG);
  await setSettings({ token: "t", signedOut: false });
});
afterEach(() => vi.unstubAllGlobals());

describe("consent card after the first save", () => {
  it("is hidden before the first successful save, and analytics stays off", async () => {
    expect(await consentCardDue(CFG)).toBe(false);
    await trackEvent({ name: "save_item", params: { source: "extension", kind: "article" } } as never);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("is due after the first successful save (any path through saveWithFallback)", async () => {
    expect(await hasSavedOnce()).toBe(false);
    expect((await saveTab({ id: 1, url: "https://a.example/x" })).ok).toBe(true);
    expect(c.storage.local.data[HAS_SAVED_KEY]).toBe(true);
    expect(await consentCardDue(CFG)).toBe(true);
  });

  it("a failed save does not count", async () => {
    fetchMock.mockImplementation(async () => jsonRes(400, { error: "invalid_url" }));
    await saveTab({ id: 1, url: "https://a.example/x" });
    expect(await hasSavedOnce()).toBe(false);
  });

  it("is hidden once answered, either way", async () => {
    await c.storage.local.set({ [HAS_SAVED_KEY]: true });
    await setConsent({ analytics: false });
    expect(await consentCardDue(CFG)).toBe(false);
    await setConsent({ analytics: true });
    expect(await consentCardDue(CFG)).toBe(false);
  });

  it("is never due in a build without analytics config", async () => {
    await c.storage.local.set({ [HAS_SAVED_KEY]: true });
    expect(await consentCardDue(null)).toBe(false);
  });

  it("renders only on the saved screen (never sign-in)", () => {
    expect(consentCardVisible("saved", true)).toBe(true);
    expect(consentCardVisible("signin", true)).toBe(false);
    expect(consentCardVisible("loading", true)).toBe(false);
    expect(consentCardVisible("saving", true)).toBe(false);
    expect(consentCardVisible("saved", false)).toBe(false);
  });

  it("holds the auto-close while the card shows", () => {
    expect(autoCloseWanted({ saved: true, consentShown: true, failedShown: false })).toBe(false);
    expect(autoCloseWanted({ saved: true, consentShown: false, failedShown: false })).toBe(true);
    expect(autoCloseWanted({ saved: true, consentShown: false, failedShown: true })).toBe(false);
    expect(autoCloseWanted({ saved: false, consentShown: false, failedShown: false })).toBe(false);
  });
});
