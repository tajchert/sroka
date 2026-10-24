import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiRequestError, api, buildQuery, describeAuthError, pollDelay, setUnauthorizedHandler } from "./api.ts";

const ITEM = {
  id: "0192f3c4-1111-7222-8333-444455556666",
  url: "https://example.com/post",
  canonicalUrl: "https://example.com/post",
  title: "Hello",
  excerpt: null,
  siteName: null,
  author: null,
  lang: null,
  leadImageUrl: null,
  leadImageKey: null,
  wordCount: null,
  readingMinutes: null,
  contentId: null,
  contentPrivate: false,
  parseStatus: "pending",
  parseError: null,
  status: "unread",
  isFavorite: false,
  progress: 0,
  progressAnchor: null,
  savedAt: 1,
  archivedAt: null,
  lastReadAt: null,
  source: "web",
  kind: "article",
  fileName: null,
  fileSize: null,
  tags: [],
  seq: 1,
};

function mockFetch(status: number, body: unknown, headers: Record<string, string> = {}) {
  const fn = vi.fn(async (..._a: unknown[]) => new Response(body === undefined ? null : JSON.stringify(body), { status, headers }));
  vi.stubGlobal("fetch", fn);
  return fn;
}

afterEach(() => {
  vi.unstubAllGlobals();
  setUnauthorizedHandler(null);
});

describe("buildQuery", () => {
  it("skips empty values and encodes", () => {
    expect(buildQuery({ q: "a b", tag: undefined, domain: "", limit: 5 })).toBe("?q=a+b&limit=5");
    expect(buildQuery({})).toBe("");
  });
});

describe("api client", () => {
  it("sends the OTP request with the sign-in type", async () => {
    const fn = mockFetch(200, { success: true });
    await api.sendOtp("a@b.c");
    const [url, init] = fn.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("/api/auth/email-otp/send-verification-otp");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toEqual({ email: "a@b.c", type: "sign-in" });
    expect(init.credentials).toBe("same-origin");
  });

  it("sends the Turnstile token header and maps TURNSTILE_FAILED", async () => {
    const fn = mockFetch(200, { success: true });
    await api.sendOtp("a@b.c", "tok123");
    const [, init] = fn.mock.calls[0] as unknown as [string, RequestInit];
    expect((init.headers as Record<string, string>)["X-Turnstile-Token"]).toBe("tok123");
    mockFetch(400, { code: "TURNSTILE_FAILED", message: "Verification failed. Please try again." });
    const err = await api.sendOtp("a@b.c", "bad").catch((e) => e);
    expect(err.code).toBe("TURNSTILE_FAILED");
    expect(describeAuthError(err)).toMatch(/verify/);
  });

  it("parses Better Auth error codes", async () => {
    mockFetch(400, { code: "INVALID_OTP", message: "Invalid OTP" });
    const err = await api.verifyOtp("a@b.c", "000000").catch((e) => e);
    expect(err).toBeInstanceOf(ApiRequestError);
    expect(err.code).toBe("INVALID_OTP");
    expect(describeAuthError(err)).toMatch(/not right/);
  });

  it("reads X-Retry-After on 429", async () => {
    mockFetch(429, { message: "Too many requests" }, { "X-Retry-After": "42" });
    const err = await api.sendOtp("a@b.c").catch((e) => e);
    expect(err.status).toBe(429);
    expect(err.retryAfter).toBe(42);
    expect(describeAuthError(err)).toContain("42 seconds");
  });

  it("lists items with a query and validates the response", async () => {
    const fn = mockFetch(200, { items: [ITEM], nextCursor: "abc" });
    const res = await api.listItems({ state: "archived", q: "bird", sort: "oldest" });
    expect(fn.mock.calls[0]![0]).toBe("/v1/items?state=archived&q=bird&sort=oldest");
    expect(res.items[0]!.title).toBe("Hello");
    expect(res.nextCursor).toBe("abc");
  });

  it("rejects malformed responses", async () => {
    mockFetch(200, { items: [{ id: 1 }], nextCursor: null });
    await expect(api.listItems({})).rejects.toThrow();
  });

  it("creates items with source web and returns created flag", async () => {
    const fn = mockFetch(202, { item: ITEM, created: true });
    const res = await api.createItem("https://example.com/post");
    expect(res.created).toBe(true);
    const init = fn.mock.calls[0]![1] as unknown as RequestInit;
    expect(JSON.parse(init.body as string)).toEqual({ url: "https://example.com/post", source: "web" });
  });

  it("handles 204 deletes and calls the unauthorized handler on 401", async () => {
    mockFetch(204, undefined);
    await expect(api.deleteItem("x")).resolves.toBeUndefined();
    const handler = vi.fn();
    setUnauthorizedHandler(handler);
    mockFetch(401, { error: "unauthorized" });
    await expect(api.deleteItem("x")).rejects.toMatchObject({ status: 401, code: "unauthorized" });
    expect(handler).toHaveBeenCalled();
  });

  it("meOrNull returns null on 401", async () => {
    mockFetch(401, { error: "unauthorized" });
    expect(await api.meOrNull()).toBeNull();
  });

  it("updateItem patches and unwraps the item", async () => {
    const fn = mockFetch(200, { item: { ...ITEM, isFavorite: true } });
    const item = await api.updateItem(ITEM.id, { isFavorite: true });
    expect(item.isFavorite).toBe(true);
    expect(fn.mock.calls[0]![1]).toMatchObject({ method: "PATCH" });
  });
});

describe("admin client", () => {
  const summary = {
    days: 7,
    since: 1,
    totals: { total: 1, ok: 1, partial: 0, failed: 0, renderTried: 0, renderOk: 0, renderBudgetBlocked: 0 },
    daily: [],
    domains: [],
  };
  it("adminSummary sends days and parses", async () => {
    const f = mockFetch(200, summary);
    expect((await api.adminSummary(7)).totals.total).toBe(1);
    expect(f.mock.calls[0]![0]).toBe("/v1/admin/parse/summary?days=7");
  });
  it("adminAttempts builds filters, skips empty", async () => {
    const f = mockFetch(200, { attempts: [], nextCursor: null });
    await api.adminAttempts({ domain: "a.com", status: "failed", method: "", limit: 50 });
    expect(f.mock.calls[0]![0]).toBe("/v1/admin/parse/attempts?domain=a.com&status=failed&limit=50");
  });
  it("adminPutRule PUTs JSON to an encoded host; delete handles 204", async () => {
    const f = mockFetch(200, { host: "a.com", rule: { render: "always", updatedAt: 1 } });
    await api.adminPutRule("a.com", { render: "always" });
    const [url, init] = f.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("/v1/admin/site-rules/a.com");
    expect(init.method).toBe("PUT");
    expect(init.body).toBe('{"render":"always"}');
    mockFetch(204, undefined);
    await expect(api.adminDeleteRule("a.com")).resolves.toBeUndefined();
  });
  it("404 for non-admins surfaces as ApiRequestError", async () => {
    mockFetch(404, { error: "not_found" });
    await expect(api.adminRules()).rejects.toMatchObject({ status: 404, code: "not_found" });
  });
});

describe("pollDelay", () => {
  it("backs off 2s,4s,8s capped at 30s", () => {
    expect([0, 1, 2, 3, 4, 5, 9].map(pollDelay)).toEqual([2000, 4000, 8000, 16000, 30000, 30000, 30000]);
  });
});
