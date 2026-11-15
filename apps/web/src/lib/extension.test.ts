import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EXTENSION_IDS, findExtension, resaveWithExtension, resetExtensionDetection } from "./extension.ts";

const ITEM = { id: "0192f3c4-0000-7000-8000-000000000001", url: "https://news.example.com/story" };
type Cb = (r: unknown) => void;

function installRuntime(handler: (id: string, msg: unknown, cb: Cb, rt: { lastError?: { message: string } }) => void) {
  const rt: { lastError?: { message: string }; sendMessage: ReturnType<typeof vi.fn> } = {
    sendMessage: vi.fn((id: string, msg: unknown, cb: Cb) => handler(id, msg, cb, rt)),
  };
  vi.stubGlobal("chrome", { runtime: rt });
  return rt;
}

beforeEach(() => resetExtensionDetection());
afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("findExtension", () => {
  it("is null without chrome.runtime (other browsers, or no extension lists this origin)", async () => {
    vi.stubGlobal("chrome", undefined);
    expect(await findExtension()).toBeNull();
    resetExtensionDetection();
    vi.stubGlobal("chrome", { runtime: {} });
    expect(await findExtension()).toBeNull();
  });

  it("is null when the id is not installed (lastError), without throwing", async () => {
    installRuntime((_id, _m, cb, rt) => {
      rt.lastError = { message: "Could not establish connection. Receiving end does not exist." };
      cb(undefined);
      rt.lastError = undefined;
    });
    expect(await findExtension()).toBeNull();
  });

  it("is null when sendMessage throws", async () => {
    installRuntime(() => {
      throw new Error("Invalid extension id");
    });
    expect(await findExtension()).toBeNull();
  });

  it("is null when nothing answers in time", async () => {
    vi.useFakeTimers();
    installRuntime(() => {});
    const p = findExtension();
    await vi.advanceTimersByTimeAsync(2000);
    expect(await p).toBeNull();
  });

  it("returns the id that answers the ping, and asks only once", async () => {
    const rt = installRuntime((_id, msg, cb) => cb((msg as { type: string }).type === "sroka.ping" ? { ok: true, version: "1" } : null));
    expect(await findExtension()).toBe(EXTENSION_IDS[0]);
    expect(await findExtension()).toBe(EXTENSION_IDS[0]);
    expect(rt.sendMessage).toHaveBeenCalledTimes(1);
    expect(rt.sendMessage.mock.calls[0]![1]).toEqual({ type: "sroka.ping" });
  });
});

describe("resaveWithExtension", () => {
  it("sends the item id and url, and reports opened", async () => {
    const rt = installRuntime((_id, _m, cb) => cb({ ok: true, opened: true, auto: false }));
    expect(await resaveWithExtension("x", ITEM)).toEqual({ ok: true, opened: true, auto: false });
    expect(rt.sendMessage).toHaveBeenCalledWith("x", { type: "sroka.resave", itemId: ITEM.id, url: ITEM.url }, expect.any(Function));
  });
  it("passes the extension's refusal through", async () => {
    installRuntime((_id, _m, cb) => cb({ ok: false, error: "signed_out" }));
    expect(await resaveWithExtension("x", ITEM)).toEqual({ ok: false, error: "signed_out" });
  });
  it("no answer → no_extension", async () => {
    installRuntime((_id, _m, cb, rt) => {
      rt.lastError = { message: "gone" };
      cb(undefined);
    });
    expect(await resaveWithExtension("x", ITEM)).toEqual({ ok: false, error: "no_extension" });
  });
});
