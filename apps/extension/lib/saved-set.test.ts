import { beforeEach, describe, expect, it, vi } from "vitest";
import { saveWithFallback } from "./save.ts";
import {
  addSaved,
  HASH_LEN,
  lookupSaved,
  META_KEY,
  refreshSavedSet,
  removeSaved,
  savedUrlHash,
  SHARD_PREFIX,
} from "./saved-set.ts";
import { clearSession, setSettings } from "./settings.ts";
import { installChrome, jsonRes, loadSavedSet, pullPage } from "./test-chrome.ts";

vi.mock("./error-reporting.ts", () => ({ installGlobalErrorHandlers: () => {} }));

const A = "01929b1e-6f1c-7a2b-9c3d-4e5f60718293";
const B = "01929b1e-6f1c-7a2b-9c3d-4e5f60718294";
const C = "01929b1e-6f1c-7a2b-9c3d-4e5f60718295";

let c: ReturnType<typeof installChrome>;
beforeEach(async () => {
  c = installChrome();
  vi.restoreAllMocks();
  await setSettings({ token: "t", email: "me@x.io", signedOut: false });
});

const storedKeys = () => Object.keys(c.storage.local.data).filter((k) => k.startsWith(SHARD_PREFIX));

describe("hashing", () => {
  it("hashes the normalized URL, compactly; nothing for non-http", async () => {
    const h = await savedUrlHash("https://a.com/p?utm_source=x&b=1#f");
    expect(h).toHaveLength(HASH_LEN);
    expect(await savedUrlHash("https://A.COM/p?b=1")).toBe(h);
    expect(await savedUrlHash("chrome://settings")).toBeNull();
  });

  it("stores hashes, never URLs", async () => {
    await loadSavedSet([{ id: A, url: "https://secret.example/path" }]);
    expect(JSON.stringify(c.storage.local.data)).not.toContain("secret.example");
  });
});

describe("lookupSaved", () => {
  it("hits on url or canonicalUrl, misses otherwise", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/x?fbclid=1", canonicalUrl: "https://a.com/x" }, { id: B, url: "http://b.com/" }]);
    expect(await lookupSaved("https://a.com/x#top")).toEqual({ saved: true, id: A });
    expect(await lookupSaved("http://B.com")).toEqual({ saved: true, id: B });
    expect(await lookupSaved("https://b.com/")).toEqual({ saved: false }); // http is not upgraded
    expect(await lookupSaved("https://c.com/")).toEqual({ saved: false });
  });

  it("is null (unknown) before the first load and after another account signs in", async () => {
    expect(await lookupSaved("https://a.com/x")).toBeNull();
    await loadSavedSet([{ id: A, url: "https://a.com/x" }]);
    await setSettings({ email: "other@x.io" });
    expect(await lookupSaved("https://a.com/x")).toBeNull();
  });
});

describe("refreshSavedSet", () => {
  it("first load is a full pass from 0 over all pages", async () => {
    const f = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(pullPage([{ id: A, url: "https://a.com/" }], { cursor: 5, hasMore: true }))
      .mockResolvedValueOnce(pullPage([{ id: B, url: "https://b.com/" }], { cursor: 9, deleted: [A] }));
    expect(await refreshSavedSet()).toBe(true);
    expect(String(f.mock.calls[0]![0])).toContain("/v1/sync/pull?cursor=0&limit=1000&full=1");
    expect(String(f.mock.calls[1]![0])).toContain("cursor=5");
    expect(await lookupSaved("https://a.com/")).toEqual({ saved: false });
    expect(await lookupSaved("https://b.com/")).toEqual({ saved: true, id: B });
    expect(c.storage.local.data[META_KEY]).toMatchObject({ cursor: 9 });
  });

  it("then pulls incrementally from the cursor, adding new items and removing tombstones", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/" }, { id: B, url: "https://b.com/" }], 7);
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(pullPage([{ id: C, url: "https://c.com/" }], { cursor: 12, deleted: [A] }));
    expect(await refreshSavedSet()).toBe(true);
    expect(String(f.mock.calls[0]![0])).toContain("cursor=7&limit=1000");
    expect(String(f.mock.calls[0]![0])).not.toContain("full=1");
    expect(await lookupSaved("https://a.com/")).toEqual({ saved: false });
    expect(await lookupSaved("https://b.com/")).toEqual({ saved: true, id: B });
    expect(await lookupSaved("https://c.com/")).toEqual({ saved: true, id: C });
    expect(c.storage.local.data[META_KEY]).toMatchObject({ cursor: 12 });
  });

  it("an empty incremental pull rewrites no shard", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/" }], 7);
    c.storage.local.set.mockClear();
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(pullPage([], { cursor: 7 }));
    await refreshSavedSet();
    expect(c.storage.local.set).toHaveBeenCalledTimes(1);
    expect(Object.keys(c.storage.local.set.mock.calls[0]![0] as object)).toEqual([META_KEY]);
  });

  it("410 resync_required → full pass that replaces the set", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/" }], 7);
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(jsonRes(410, { error: "resync_required" }))
      .mockResolvedValueOnce(pullPage([{ id: B, url: "https://b.com/" }], { cursor: 40 }));
    expect(await refreshSavedSet()).toBe(true);
    expect(await lookupSaved("https://a.com/")).toEqual({ saved: false });
    expect(await lookupSaved("https://b.com/")).toEqual({ saved: true, id: B });
  });

  it("a failed refresh keeps the previous set; signed out does nothing", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/" }], 7);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("offline"));
    expect(await refreshSavedSet()).toBe(false);
    expect(await lookupSaved("https://a.com/")).toEqual({ saved: true, id: A });
    await setSettings({ signedOut: true });
    const f = vi.spyOn(globalThis, "fetch");
    f.mockClear();
    expect(await refreshSavedSet()).toBe(false);
    expect(f).not.toHaveBeenCalled();
  });

  it("another account: clears and reloads from 0", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/" }], 7);
    await setSettings({ email: "other@x.io" });
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(pullPage([{ id: B, url: "https://b.com/" }], { cursor: 3 }));
    await refreshSavedSet();
    expect(String(f.mock.calls[0]![0])).toContain("cursor=0");
    expect(await lookupSaved("https://a.com/")).toEqual({ saved: false });
    expect(await lookupSaved("https://b.com/")).toEqual({ saved: true, id: B });
  });
});

describe("local updates", () => {
  it("save adds the item, delete removes it, touching one shard", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/" }]);
    c.storage.local.set.mockClear();
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      jsonRes(202, { item: { id: B, url: "https://b.com/p?utm_medium=x", canonicalUrl: "https://b.com/p" }, created: true }),
    );
    expect((await saveWithFallback({ url: "https://b.com/p?utm_medium=x" })).ok).toBe(true);
    expect(await lookupSaved("https://b.com/p")).toEqual({ saved: true, id: B });
    const written = c.storage.local.set.mock.calls.map((call) => Object.keys(call[0] as object)).flat();
    expect(written).toHaveLength(1);
    await removeSaved(B, ["https://b.com/p"]);
    expect(await lookupSaved("https://b.com/p")).toEqual({ saved: false });
    expect(await lookupSaved("https://a.com/")).toEqual({ saved: true, id: A });
  });

  it("does nothing while the set is not loaded", async () => {
    await addSaved({ id: A, url: "https://a.com/" });
    expect(storedKeys()).toEqual([]);
    expect(await lookupSaved("https://a.com/")).toBeNull();
  });

  it("sign-out clears the set", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/" }]);
    expect(storedKeys().length).toBeGreaterThan(1);
    await clearSession();
    expect(storedKeys()).toEqual([]);
    await setSettings({ token: "t2", email: "me@x.io", signedOut: false });
    expect(await lookupSaved("https://a.com/")).toBeNull();
  });
});

describe("background", () => {
  it("tab updates and activation never make a request", async () => {
    await loadSavedSet([{ id: A, url: "https://a.com/x" }]);
    type Fn = (...a: unknown[]) => unknown;
    const listeners: Record<string, Fn> = {};
    const ev = (name: string) => ({ addListener: (fn: Fn) => void (listeners[name] = fn) });
    Object.assign(c, {
      runtime: { ...c.runtime, onInstalled: ev("installed"), onStartup: ev("startup"), onMessage: ev("message") },
      contextMenus: { onClicked: ev("menu"), update: vi.fn(async () => {}) },
      tabs: { onActivated: ev("activated"), onUpdated: ev("updated"), get: vi.fn(async (id: number) => ({ id, url: id === 7 ? "https://a.com/x" : "https://private.example/", active: true })) },
      windows: { onFocusChanged: ev("focus"), WINDOW_ID_NONE: -1 },
      alarms: { ...c.alarms, onAlarm: ev("alarm") },
      storage: { ...c.storage, onChanged: ev("storage") },
    });
    vi.stubGlobal("defineBackground", (fn: () => void) => fn);
    vi.stubGlobal("__SROKA_GA__", null);
    const f = vi.spyOn(globalThis, "fetch");
    const bg = (await import("../entrypoints/background.ts")).default as unknown as () => void;
    bg();
    listeners.updated!(7, { status: "loading" }, { url: "https://a.com/x" });
    listeners.updated!(8, { url: "https://private.example/" }, { url: "https://private.example/" });
    await listeners.activated!({ tabId: 7 });
    await vi.waitFor(() => expect(c.action.setBadgeText).toHaveBeenCalledWith({ tabId: 7, text: "✓" }));
    await vi.waitFor(() => expect(c.action.setBadgeText).toHaveBeenCalledWith({ tabId: 8, text: "" }));
    expect(f).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });
});
