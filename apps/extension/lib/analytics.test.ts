import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SESSION_MS, setTrackSink, track, trackEvent } from "./analytics.ts";
import { CLIENT_ID_KEY, getConsent, setConsent, shouldShowConsentPrompt } from "./consent.ts";
import { installChrome } from "./test-chrome.ts";

const CFG = { measurementId: "G-TEST", apiSecret: "sekret" };

describe("consent + analytics", () => {
  let chromeMock: ReturnType<typeof installChrome>;
  let fetchMock: ReturnType<typeof vi.fn<typeof globalThis.fetch>>;
  beforeEach(() => {
    chromeMock = installChrome();
    fetchMock = vi.fn<typeof globalThis.fetch>(async () => new Response(null));
    vi.stubGlobal("fetch", fetchMock);
    vi.stubGlobal("__SROKA_GA__", CFG);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    setTrackSink(null);
  });

  it("defaults: analytics undecided, errors on", async () => {
    expect(await getConsent()).toEqual({ analytics: null, errors: true });
  });

  it("sends nothing and creates no client id before consent or after refusal", async () => {
    expect(await trackEvent({ name: "popup_open" })).toBe(false);
    await setConsent({ analytics: false });
    expect(await trackEvent({ name: "popup_open" })).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(chromeMock.storage.local.data[CLIENT_ID_KEY]).toBeUndefined();
  });

  it("is a no-op without a build-time config even with consent", async () => {
    vi.stubGlobal("__SROKA_GA__", null);
    await setConsent({ analytics: true });
    expect(await trackEvent({ name: "popup_open" })).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("sends a no-cors string-body MP hit with client_id, session_id and engagement time", async () => {
    await setConsent({ analytics: true });
    expect(await trackEvent({ name: "save_item", params: { source: "extension", kind: "article" } }, 1_700_000_000_000)).toBe(true);
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(String(url)).toBe("https://www.google-analytics.com/mp/collect?measurement_id=G-TEST&api_secret=sekret");
    expect(init?.method).toBe("POST");
    expect(init?.mode).toBe("no-cors");
    expect(typeof init?.body).toBe("string");
    const body = JSON.parse(init!.body as string);
    expect(body.client_id).toBe(chromeMock.storage.local.data[CLIENT_ID_KEY]);
    expect(body.events).toEqual([
      { name: "save_item", params: { source: "extension", kind: "article", session_id: 1_700_000_000, engagement_time_msec: 100 } },
    ]);
  });

  it("drops params outside the D15 enums", async () => {
    await setConsent({ analytics: true });
    await trackEvent({ name: "save_item", params: { source: "extension", kind: "article", url: "https://x.test" } } as never);
    await trackEvent({ name: "login", params: { method: "password" } } as never);
    const [a, b] = fetchMock.mock.calls.map(([, i]) => JSON.parse(i!.body as string).events[0].params);
    expect(a.url).toBeUndefined();
    expect(b.method).toBeUndefined();
  });

  it("keeps the client id across events and rotates the session after 30 min of inactivity", async () => {
    await setConsent({ analytics: true });
    const t0 = 1_700_000_000_000;
    await trackEvent({ name: "popup_open" }, t0);
    await trackEvent({ name: "popup_open" }, t0 + SESSION_MS - 1);
    await trackEvent({ name: "popup_open" }, t0 + 2 * SESSION_MS);
    const bodies = fetchMock.mock.calls.map(([, i]) => JSON.parse(i!.body as string));
    expect(new Set(bodies.map((b) => b.client_id)).size).toBe(1);
    const ids = bodies.map((b) => b.events[0].params.session_id);
    expect(ids[1]).toBe(ids[0]);
    expect(ids[2]).not.toBe(ids[0]);
  });

  it("revoking deletes the client id; re-consent mints a new one", async () => {
    await setConsent({ analytics: true });
    await trackEvent({ name: "popup_open" });
    const first = chromeMock.storage.local.data[CLIENT_ID_KEY];
    expect(first).toBeTruthy();
    await setConsent({ analytics: false });
    expect(chromeMock.storage.local.data[CLIENT_ID_KEY]).toBeUndefined();
    await setConsent({ analytics: true });
    await trackEvent({ name: "popup_open" });
    expect(chromeMock.storage.local.data[CLIENT_ID_KEY]).not.toBe(first);
  });

  it("track() goes through a runtime message by default and through the sink in the background", async () => {
    track({ name: "open_library" });
    expect(chromeMock.runtime.sendMessage).toHaveBeenCalledWith({ type: "track", event: { name: "open_library" } });
    const sink = vi.fn(async () => true);
    setTrackSink(sink);
    track({ name: "popup_open" });
    expect(sink).toHaveBeenCalledWith({ name: "popup_open" });
  });

  it("shows the prompt only when configured and undecided", () => {
    expect(shouldShowConsentPrompt({ analytics: null, errors: true }, CFG)).toBe(true);
    expect(shouldShowConsentPrompt({ analytics: null, errors: true }, null)).toBe(false);
    expect(shouldShowConsentPrompt({ analytics: true, errors: true }, CFG)).toBe(false);
    expect(shouldShowConsentPrompt({ analytics: false, errors: true }, CFG)).toBe(false);
  });
});
