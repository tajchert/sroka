import { beforeEach, describe, expect, it, vi } from "vitest";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes } from "./test-chrome.ts";
import { openApp } from "./open-app.ts";

describe("openApp", () => {
  let chromeMock: ReturnType<typeof installChrome> & { tabs?: { create: ReturnType<typeof vi.fn> } };
  beforeEach(() => {
    chromeMock = installChrome();
    chromeMock.tabs = { create: vi.fn(async () => ({})) };
  });

  it("uses appOrigin from /v1/config", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonRes(200, { appOrigin: "https://web.example" })));
    await openApp();
    expect(chromeMock.tabs!.create).toHaveBeenCalledWith({ url: "https://web.example/app/" });
  });

  it("falls back to sroka.app when the config request fails", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("offline"); }));
    await openApp("item/abc");
    expect(chromeMock.tabs!.create).toHaveBeenCalledWith({ url: "https://sroka.app/app/item/abc" });
  });

  it("falls back to a custom server's own origin", async () => {
    await setSettings({ serverUrl: "https://read.example" });
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("offline"); }));
    await openApp();
    expect(chromeMock.tabs!.create).toHaveBeenCalledWith({ url: "https://read.example/app/" });
  });
});
