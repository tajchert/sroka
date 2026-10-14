import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiFailure, lookupUrl, saveItem, signIn } from "./api.ts";
import { getSettings, setSettings } from "./settings.ts";
import { installChrome, jsonRes } from "./test-chrome.ts";

const fail = (p: Promise<unknown>) => p.then(() => { throw new Error("expected failure"); }, (e: unknown) => e as ApiFailure);
let c: ReturnType<typeof installChrome>;
beforeEach(() => {
  c = installChrome();
  vi.restoreAllMocks();
});

describe("api client", () => {
  it("sends bearer + device header to configured server", async () => {
    await setSettings({ token: "tok.en=", signedOut: false, serverUrl: "http://localhost:8787" });
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(202, { item: { id: "1" }, created: true }));
    await saveItem({ url: "https://a.com/", source: "extension" });
    const [url, init] = f.mock.calls[0]!;
    expect(url).toBe("http://localhost:8787/v1/items");
    const h = (init as RequestInit).headers as Record<string, string>;
    expect(h.authorization).toBe("Bearer tok.en=");
    expect(h["x-sroka-device"]).toMatch(/^ext-/);
    expect(JSON.parse((init as RequestInit).body as string)).toEqual({ url: "https://a.com/", source: "extension" });
  });

  it("marks signed out on 401 but keeps token fields intact except flag", async () => {
    await setSettings({ token: "t", signedOut: false });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(401, { error: "unauthorized" }));
    await expect(lookupUrl("https://a.com")).rejects.toMatchObject({ status: 401 });
    expect((await getSettings()).signedOut).toBe(true);
  });

  it("without a token fails 401 without calling fetch", async () => {
    const f = vi.spyOn(globalThis, "fetch");
    await expect(lookupUrl("https://a.com")).rejects.toBeInstanceOf(ApiFailure);
    expect(f).not.toHaveBeenCalled();
  });

  it("network error → status 0, retryable", async () => {
    await setSettings({ token: "t", signedOut: false });
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("fail"));
    const e = await fail(saveItem({ url: "https://a.com" }));
    expect(e.status).toBe(0);
    expect(e.retryable).toBe(true);
  });

  it("parses 429 Retry-After", async () => {
    await setSettings({ token: "t", signedOut: false });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(429, { error: "rate_limited" }, { "retry-after": "12" }));
    const e = await fail(saveItem({ url: "https://a.com" }));
    expect(e.retryAfter).toBe(12);
  });

  it("signIn stores set-auth-token verbatim", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(200, { token: "x" }, { "set-auth-token": "abc.def==" }));
    await signIn("a@b.c", "123456");
    const s = await getSettings();
    expect(s).toMatchObject({ token: "abc.def==", email: "a@b.c", signedOut: false });
    expect(c.storage.local.data.token).toBe("abc.def==");
  });

  it("signIn surfaces Better Auth code", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(400, { code: "INVALID_OTP", message: "bad" }));
    await expect(signIn("a@b.c", "000000")).rejects.toMatchObject({ code: "INVALID_OTP" });
  });
});
