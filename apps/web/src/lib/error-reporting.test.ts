import { beforeEach, describe, expect, it, vi } from "vitest";
import { reportClientError, resetErrorReporting } from "./error-reporting.ts";

describe("reportClientError", () => {
  beforeEach(() => {
    resetErrorReporting();
    vi.stubGlobal("location", { pathname: "/app/item/1" });
    vi.stubGlobal("navigator", { userAgent: "test-ua" });
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 204 })));
  });

  it("posts the error once and dedupes repeats", () => {
    const e = new Error("boom");
    expect(reportClientError(e)).toBe(true);
    expect(reportClientError(e)).toBe(false);
    const f = vi.mocked(fetch);
    expect(f).toHaveBeenCalledTimes(1);
    const [url, init] = f.mock.calls[0]!;
    expect(url).toBe("/v1/client-errors");
    const body = JSON.parse((init as RequestInit).body as string);
    expect(body).toMatchObject({ message: "boom", url: "/app/item/1", userAgent: "test-ua" });
    expect(body.stack.length).toBeLessThanOrEqual(4096);
  });

  it("caps reports per session", () => {
    let n = 0;
    for (let i = 0; i < 25; i++) if (reportClientError(new Error(`e${i}`))) n++;
    expect(n).toBe(10);
  });
});
