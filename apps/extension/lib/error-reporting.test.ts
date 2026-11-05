import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { setConsent } from "./consent.ts";
import { MAX_PER_SESSION, reportClientError, resetErrorReporting } from "./error-reporting.ts";
import { setSettings } from "./settings.ts";
import { installChrome } from "./test-chrome.ts";

describe("reportClientError", () => {
  let fetchMock: ReturnType<typeof vi.fn<typeof globalThis.fetch>>;
  beforeEach(() => {
    installChrome();
    resetErrorReporting();
    fetchMock = vi.fn<typeof globalThis.fetch>(async () => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
  });
  afterEach(() => vi.unstubAllGlobals());

  it("posts the api.md §12 body to the configured server, with the extension release and no tab URL", async () => {
    await setSettings({ serverUrl: "https://srv.test" });
    expect(await reportClientError(new Error("boom"), "uncaught")).toBe(true);
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe("https://srv.test/v1/client-errors");
    const body = JSON.parse(init!.body as string);
    expect(body.message).toBe("uncaught: boom");
    expect(body.release).toBe("ext-9.9.9");
    expect(body.url).toBe("/background");
    expect(body.stack).toContain("boom");
  });

  it("dedupes identical errors", async () => {
    const e = new Error("same");
    expect(await reportClientError(e)).toBe(true);
    expect(await reportClientError(e)).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("caps at 10 per session", async () => {
    for (let i = 0; i < MAX_PER_SESSION + 5; i++) await reportClientError(`err ${i}`);
    expect(fetchMock).toHaveBeenCalledTimes(MAX_PER_SESSION);
  });

  it("sends nothing when crash reports are switched off", async () => {
    await setConsent({ errors: false });
    expect(await reportClientError(new Error("x"))).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
