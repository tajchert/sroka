import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  allowedOrigin,
  forgetResaveTab,
  handleExternal,
  onResaveTabUpdated,
  pageKey,
  parseExternal,
  RESAVE_BADGE,
  RESAVE_KEY,
  RESAVE_TTL_MS,
  resaveHintFor,
  takeResave,
} from "./resave.ts";
import type { ResaveDeps } from "./resave.ts";
import type { SaveResult } from "./save.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes } from "./test-chrome.ts";

const ID = "0192f3c4-0000-7000-8000-000000000001";
const URL_ = "https://news.example.com/2026/story";
const MATCHES = ["https://sroka.app/*", "http://localhost/*"];
const web = { origin: "https://sroka.app", tab: { id: 3, index: 0, windowId: 1 } };

type Fn = ReturnType<typeof vi.fn>;
let c: ReturnType<typeof installChrome> & { tabs: { create: Fn; get: Fn }; permissions: { contains: Fn }; action: { setTitle: Fn } };
let hostAccess: boolean;
let fetches: string[];
let item: Record<string, unknown> | null;

beforeEach(async () => {
  const base = installChrome();
  base.runtime.getManifest.mockReturnValue({ version: "9.9.9", externally_connectable: { matches: MATCHES } } as never);
  hostAccess = true;
  c = Object.assign(base, {
    tabs: {
      create: vi.fn(async () => ({ id: 42 })),
      get: vi.fn(async () => ({ id: 42, url: URL_, title: "Story" })),
    },
    permissions: { contains: vi.fn(async () => hostAccess) },
    action: { ...base.action, setTitle: vi.fn(async () => {}) },
  });
  vi.restoreAllMocks();
  fetches = [];
  item = { id: ID, url: URL_, canonicalUrl: URL_ };
  vi.spyOn(globalThis, "fetch").mockImplementation((async (u: string) => {
    fetches.push(u);
    return item ? jsonRes(200, { item }) : jsonRes(404, { error: "not_found" });
  }) as never);
  await setSettings({ token: "t", signedOut: false });
});

describe("allowedOrigin", () => {
  it("accepts only the manifest origins", () => {
    expect(allowedOrigin("https://sroka.app", MATCHES)).toBe(true);
    expect(allowedOrigin("http://localhost:5173", MATCHES)).toBe(true);
    expect(allowedOrigin("http://localhost:8807", MATCHES)).toBe(true);
    expect(allowedOrigin("http://sroka.app", MATCHES)).toBe(false);
    expect(allowedOrigin("https://evil.sroka.app", MATCHES)).toBe(false);
    expect(allowedOrigin("https://sroka.app.evil.com", MATCHES)).toBe(false);
    expect(allowedOrigin("https://localhost", MATCHES)).toBe(false);
    expect(allowedOrigin(undefined, MATCHES)).toBe(false);
    expect(allowedOrigin("https://sroka.app", ["https://sroka.app/*"])).toBe(true);
    expect(allowedOrigin("http://localhost:5173", ["https://sroka.app/*"])).toBe(false);
  });
});

describe("parseExternal", () => {
  it("validates type, uuid and http(s) url", () => {
    expect(parseExternal({ type: "sroka.ping" })).toEqual({ type: "sroka.ping" });
    expect(parseExternal({ type: "sroka.resave", itemId: ID, url: URL_ })).toEqual({ type: "sroka.resave", itemId: ID, url: URL_ });
    expect(parseExternal({ type: "sroka.resave", itemId: ID, url: "javascript:alert(1)" })).toBeNull();
    expect(parseExternal({ type: "sroka.resave", itemId: ID, url: "file:///etc/passwd" })).toBeNull();
    expect(parseExternal({ type: "sroka.resave", itemId: "nope", url: URL_ })).toBeNull();
    expect(parseExternal({ type: "save-tab" })).toBeNull();
    expect(parseExternal("sroka.ping")).toBeNull();
    expect(parseExternal(null)).toBeNull();
  });
});

describe("pageKey", () => {
  it("ignores scheme, www, tracking params and a trailing slash", () => {
    expect(pageKey("http://www.example.com/a/?utm_source=x")).toBe(pageKey("https://example.com/a"));
    expect(pageKey("https://example.com/a")).not.toBe(pageKey("https://example.com/login"));
    expect(pageKey("chrome://newtab")).toBeNull();
  });
});

describe("handleExternal", () => {
  it("answers a ping from the web app with the version", async () => {
    expect(await handleExternal({ type: "sroka.ping" }, { origin: "https://sroka.app" })).toEqual({ ok: true, version: "9.9.9" });
  });
  it("refuses other origins before doing anything", async () => {
    expect(await handleExternal({ type: "sroka.ping" }, { origin: "https://evil.example" })).toEqual({ ok: false, error: "bad_origin" });
    const r = await handleExternal({ type: "sroka.resave", itemId: ID, url: URL_ }, { ...web, origin: "https://evil.example" });
    expect(r).toEqual({ ok: false, error: "bad_origin" });
    expect(fetches).toHaveLength(0);
    expect(c.tabs.create).not.toHaveBeenCalled();
  });
  it("falls back to sender.url when origin is missing", async () => {
    expect(await handleExternal({ type: "sroka.ping" }, { url: "https://sroka.app/app/item/x" })).toMatchObject({ ok: true });
  });
  it("refuses a malformed message or one not sent from a tab", async () => {
    expect(await handleExternal({ type: "sroka.resave", itemId: ID, url: "ftp://x" }, web)).toEqual({ ok: false, error: "bad_request" });
    expect(await handleExternal({ type: "sroka.resave", itemId: ID, url: URL_ }, { origin: "https://sroka.app" })).toEqual({
      ok: false,
      error: "bad_request",
    });
  });
  it("opens the item's URL next to the web tab and remembers that tab", async () => {
    const r = await handleExternal({ type: "sroka.resave", itemId: ID, url: URL_ }, web, 1000);
    expect(r).toEqual({ ok: true, opened: true, auto: true });
    expect(fetches[0]).toContain(`/v1/items/${ID}`);
    expect(c.tabs.create).toHaveBeenCalledWith(expect.objectContaining({ url: URL_, active: true, openerTabId: 3, index: 1, windowId: 1 }));
    const pending = (c.storage.session.data[RESAVE_KEY] as Record<string, { itemId: string; expires: number }>)["42"];
    expect(pending).toMatchObject({ itemId: ID, expires: 1000 + RESAVE_TTL_MS });
  });
  it("refuses an item that is not in the extension's library", async () => {
    item = null;
    expect(await handleExternal({ type: "sroka.resave", itemId: ID, url: URL_ }, web)).toEqual({ ok: false, error: "not_in_library" });
    expect(c.tabs.create).not.toHaveBeenCalled();
  });
  it("refuses when the URL does not match the item", async () => {
    const r = await handleExternal({ type: "sroka.resave", itemId: ID, url: "https://other.example/x" }, web);
    expect(r).toEqual({ ok: false, error: "not_in_library" });
    expect(c.tabs.create).not.toHaveBeenCalled();
  });
  it("reports signed_out without a token", async () => {
    await setSettings({ token: undefined });
    expect(await handleExternal({ type: "sroka.resave", itemId: ID, url: URL_ }, web)).toEqual({ ok: false, error: "signed_out" });
  });
});

describe("without host access (the usual case): badge hint, then the user's click saves", () => {
  const ok: SaveResult = { ok: true, item: { id: ID } as never, created: false };
  beforeEach(async () => {
    hostAccess = false;
    expect(await handleExternal({ type: "sroka.resave", itemId: ID, url: URL_ }, web)).toEqual({ ok: true, opened: true, auto: false });
  });

  it("does not save on load; paints the hint on that tab only", async () => {
    const save = vi.fn(async () => ok);
    expect(await onResaveTabUpdated(42, { status: "complete" }, { url: URL_ }, { save, delay: async () => {} })).toBeNull();
    expect(save).not.toHaveBeenCalled();
    expect(c.action.setBadgeText).toHaveBeenCalledWith({ tabId: 42, text: RESAVE_BADGE });
    expect(await resaveHintFor(42, URL_)).toBe(true);
    expect(await resaveHintFor(7, URL_)).toBe(false);
    expect(await resaveHintFor(42, "https://news.example.com/login")).toBe(false);
  });

  it("takeResave claims the tab once, only on the requested page, and returns the item URL", async () => {
    expect(await takeResave(7, URL_)).toBeNull();
    expect(await takeResave(42, "https://news.example.com/login")).toBeNull();
    expect(await takeResave(42, `${URL_}/`)).toEqual({ url: URL_ });
    expect(await takeResave(42, URL_)).toBeNull();
    expect(await resaveHintFor(42, URL_)).toBe(false);
  });
});

describe("onResaveTabUpdated (only the tab it opened)", () => {
  const ok: SaveResult = { ok: true, item: { id: ID } as never, created: false };
  let save: ReturnType<typeof vi.fn<ResaveDeps["save"]>>;
  const deps = () => ({ save, delay: async () => {} });

  beforeEach(async () => {
    save = vi.fn<ResaveDeps["save"]>(async () => ok);
    await handleExternal({ type: "sroka.resave", itemId: ID, url: URL_ }, web);
  });

  it("saves the opened tab once it has loaded the page, with the item's URL", async () => {
    expect(await onResaveTabUpdated(42, { status: "complete" }, { url: URL_ }, deps())).toBe(ok);
    expect(save).toHaveBeenCalledWith({ id: 42, url: URL_, title: "Story" });
    // Claimed: a second "complete" does not save again.
    expect(await onResaveTabUpdated(42, { status: "complete" }, { url: URL_ }, deps())).toBeNull();
    expect(save).toHaveBeenCalledTimes(1);
  });
  it("never saves any other tab", async () => {
    expect(await onResaveTabUpdated(7, { status: "complete" }, { url: URL_ }, deps())).toBeNull();
    expect(save).not.toHaveBeenCalled();
  });
  it("ignores loading events", async () => {
    expect(await onResaveTabUpdated(42, { status: "loading" }, { url: URL_ }, deps())).toBeNull();
    expect(save).not.toHaveBeenCalled();
  });
  it("waits while the tab shows another page (login), then saves when it is back", async () => {
    expect(await onResaveTabUpdated(42, { status: "complete" }, { url: "https://news.example.com/login" }, deps())).toBeNull();
    expect(save).not.toHaveBeenCalled();
    expect(await onResaveTabUpdated(42, { status: "complete" }, { url: `${URL_}?utm_source=x` }, deps())).toBe(ok);
  });
  it("does not save when the tab navigated away during the settle delay", async () => {
    c.tabs.get.mockResolvedValueOnce({ id: 42, url: "https://elsewhere.example/", title: "x" });
    expect(await onResaveTabUpdated(42, { status: "complete" }, { url: URL_ }, deps())).toBeNull();
    expect(save).not.toHaveBeenCalled();
  });
  it("expires after the TTL", async () => {
    const later = { ...deps(), now: () => Date.now() + RESAVE_TTL_MS + 1 };
    expect(await onResaveTabUpdated(42, { status: "complete" }, { url: URL_ }, later)).toBeNull();
    expect(save).not.toHaveBeenCalled();
  });
  it("forgets a closed tab", async () => {
    await forgetResaveTab(42);
    expect(await onResaveTabUpdated(42, { status: "complete" }, { url: URL_ }, deps())).toBeNull();
  });
});
