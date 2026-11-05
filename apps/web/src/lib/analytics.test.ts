import { beforeEach, describe, expect, it, vi } from "vitest";

const analyticsMod = vi.hoisted(() => ({
  setConsent: vi.fn(),
  initializeAnalytics: vi.fn(() => ({ id: "inst" })),
  setAnalyticsCollectionEnabled: vi.fn(),
  setDefaultEventParameters: vi.fn(),
  logEvent: vi.fn(),
}));
const appMod = vi.hoisted(() => ({ initializeApp: vi.fn(() => ({ app: true })) }));
const cfg = vi.hoisted(() => ({ value: { apiKey: "k", authDomain: "d", projectId: "p", appId: "a", measurementId: "G-1" } as unknown }));

vi.mock("firebase/analytics", () => analyticsMod);
vi.mock("firebase/app", () => appMod);
vi.mock("./firebase-config.ts", () => ({
  get firebaseConfig() {
    return cfg.value;
  },
  hasAnalyticsConfig: () => cfg.value !== null,
}));

import { resetAnalytics, screenForPath, setScreen, startAnalytics, track } from "./analytics.ts";
import { resetConsentCache, setConsent } from "./consent.ts";

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("screenForPath", () => {
  it("maps routes to screens with route patterns, dropping ids, names and queries", () => {
    expect(screenForPath("/item/0190abc")).toEqual({ screen_name: "reader", page_path: "/app/item/:id" });
    expect(screenForPath("/tag/secret-tag")).toEqual({ screen_name: "library", page_path: "/app/tag/:name" });
    expect(screenForPath("/search")).toEqual({ screen_name: "search", page_path: "/app/search" });
    expect(screenForPath("/")).toEqual({ screen_name: "library", page_path: "/app" });
    expect(screenForPath("/archive")).toEqual({ screen_name: "library", page_path: "/app/archive" });
    expect(screenForPath("/settings")?.screen_name).toBe("settings");
    expect(screenForPath("/admin")).toBeNull();
  });
});

describe("analytics loading", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    resetConsentCache();
    resetAnalytics();
    cfg.value = { apiKey: "k", authDomain: "d", projectId: "p", appId: "a", measurementId: "G-1" };
  });

  it("does not load firebase before consent", async () => {
    startAnalytics();
    await flush();
    expect(appMod.initializeApp).not.toHaveBeenCalled();
    track({ name: "delete_item" });
    expect(analyticsMod.logEvent).not.toHaveBeenCalled();
  });

  it("does not load firebase without a config even with consent", async () => {
    cfg.value = null;
    setConsent({ analytics: true });
    startAnalytics();
    await flush();
    expect(appMod.initializeApp).not.toHaveBeenCalled();
  });

  it("loads after consent with consent mode set first and sanitized location", async () => {
    startAnalytics();
    setScreen({ screen_name: "reader", page_path: "/app/item/:id" });
    setConsent({ analytics: true });
    await flush();
    expect(analyticsMod.setConsent).toHaveBeenCalledWith({
      analytics_storage: "granted",
      ad_storage: "denied",
      ad_user_data: "denied",
      ad_personalization: "denied",
    });
    expect(analyticsMod.setConsent.mock.invocationCallOrder[0]!).toBeLessThan(analyticsMod.initializeAnalytics.mock.invocationCallOrder[0]!);
    expect(analyticsMod.initializeAnalytics).toHaveBeenCalledWith(expect.anything(), {
      config: { send_page_view: false, allow_google_signals: false, allow_ad_personalization_signals: false },
    });
    const loc = location.origin + "/app/item/:id";
    expect(analyticsMod.setDefaultEventParameters).toHaveBeenCalledWith({ page_location: loc, page_path: "/app/item/:id" });
    expect(analyticsMod.logEvent).toHaveBeenCalledWith(expect.anything(), "screen_view", {
      screen_name: "reader",
      page_location: loc,
      page_path: "/app/item/:id",
    });
    track({ name: "favorite_item", params: { on: true } });
    expect(analyticsMod.logEvent).toHaveBeenLastCalledWith(expect.anything(), "favorite_item", { on: true });
  });

  it("revoking disables collection and denies consent", async () => {
    startAnalytics();
    setConsent({ analytics: true });
    await flush();
    setConsent({ analytics: false });
    expect(analyticsMod.setAnalyticsCollectionEnabled).toHaveBeenLastCalledWith(expect.anything(), false);
    expect(analyticsMod.setConsent).toHaveBeenLastCalledWith(expect.objectContaining({ analytics_storage: "denied" }));
    analyticsMod.logEvent.mockClear();
    track({ name: "delete_item" });
    expect(analyticsMod.logEvent).not.toHaveBeenCalled();
  });
});
