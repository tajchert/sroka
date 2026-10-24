import { describe, expect, it } from "vitest";
import { signContentPath } from "@sroka/shared";
import { call, testEnv, APP } from "./helpers.ts";

const CONTENT = "http://127.0.0.1:8787";
const KEY = testEnv.CONTENT_URL_SIGNING_KEY;
const CID = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";

async function url(scope: string, file: string, exp = Math.floor(Date.now() / 1000) + 3600): Promise<string> {
  const sig = await signContentPath(KEY, exp, scope as "p", CID);
  return `/s/${exp}/${sig}/${scope}/${CID}/${file}`;
}

describe("content route", () => {
  it("serves public content with headers and CORS", async () => {
    await testEnv.CONTENT.put(`content/${CID}/article.html`, "<p>hi</p>");
    const res = await call(await url("p", "article.html"), { headers: { origin: APP } }, CONTENT);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("<p>hi</p>");
    expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(res.headers.get("cache-control")).toBe("public, max-age=86400, immutable");
    expect(res.headers.get("access-control-allow-origin")).toBe(APP);
    expect(res.headers.get("vary")).toBe("Origin");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("content-security-policy")).toContain("sandbox");
  });

  it("dev origin allowed, foreign origin not; private is no-store", async () => {
    await testEnv.CONTENT.put(`private/u1/${CID}/article.html`, "secret");
    const p = await url("u.u1", "article.html");
    const dev = await call(p, { headers: { origin: "http://localhost:5173" } }, CONTENT);
    expect(dev.status).toBe(200);
    expect(dev.headers.get("access-control-allow-origin")).toBe("http://localhost:5173");
    expect(dev.headers.get("cache-control")).toBe("private, no-store");
    const evil = await call(p, { headers: { origin: "https://evil.example" } }, CONTENT);
    expect(evil.headers.get("access-control-allow-origin")).toBeNull();
    expect(evil.headers.get("vary")).toBe("Origin");
  });

  it("403 bad signature / expired / malformed, 404 miss, 405 method", async () => {
    const good = await url("p", "article.html");
    const tampered = good.replace(`/p/${CID}`, `/u.x/${CID}`);
    const bad = await call(tampered, {}, CONTENT);
    expect(bad.status).toBe(403);
    expect(((await bad.json()) as { message: string }).message).toBe("bad_signature");
    const expired = await call(await url("p", "article.html", Math.floor(Date.now() / 1000) - 10), {}, CONTENT);
    expect(expired.status).toBe(403);
    expect(((await expired.json()) as { message: string }).message).toBe("expired");
    expect((await call("/s/1/2/3", {}, CONTENT)).status).toBe(403);
    expect((await call(await url("p", "missing.html"), {}, CONTENT)).status).toBe(404);
    expect((await call(good, { method: "POST" }, CONTENT)).status).toBe(405);
    expect((await call("/v1/health", {}, CONTENT)).status).toBe(404);
  });

  it("honours If-None-Match", async () => {
    await testEnv.CONTENT.put(`content/${CID}/text.txt`, "abc");
    const p = await url("p", "text.txt");
    const first = await call(p, {}, CONTENT);
    const etag = first.headers.get("etag")!;
    const second = await call(p, { headers: { "if-none-match": etag } }, CONTENT);
    expect(second.status).toBe(304);
  });
});

describe("API CORS", () => {
  it("preflight for extension and app origin; none for foreign", async () => {
    const pre = (origin: string) =>
      call("/v1/items", { method: "OPTIONS", headers: { origin, "access-control-request-method": "POST", "access-control-request-headers": "authorization" } });
    const ext = await pre("chrome-extension://abcdef");
    expect(ext.headers.get("access-control-allow-origin")).toBe("chrome-extension://abcdef");
    expect(ext.headers.get("access-control-allow-headers")).toContain("X-Sroka-Device");
    expect((await pre("moz-extension://x")).headers.get("access-control-allow-origin")).toBe("moz-extension://x");
    expect((await pre(APP)).headers.get("access-control-allow-origin")).toBe(APP);
    expect((await pre("https://evil.example")).headers.get("access-control-allow-origin")).toBeNull();
  });

  it("exposes set-auth-token on responses", async () => {
    const res = await call("/v1/health", { headers: { origin: "chrome-extension://abc" } });
    expect(res.headers.get("access-control-expose-headers")).toContain("set-auth-token");
    expect(res.headers.get("access-control-expose-headers")).toContain("X-Retry-After");
  });
});

describe("pdf content", () => {
  it("serves .pdf with application/pdf, inline disposition and a CSP without sandbox", async () => {
    await testEnv.CONTENT.put(`private/u1/${CID}/document.pdf`, "%PDF-1.4 hi");
    const res = await call(await url("u.u1", "document.pdf"), { headers: { origin: APP } }, CONTENT);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/pdf");
    expect(res.headers.get("content-disposition")).toBe('inline; filename="document.pdf"');
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("cache-control")).toBe("private, no-store");
    expect(res.headers.get("access-control-allow-origin")).toBe(APP);
    const csp = res.headers.get("content-security-policy")!;
    expect(csp).not.toContain("sandbox");
    expect(csp).toContain("object-src 'none'");
    expect(csp).toContain("frame-ancestors 'none'");
  });
});
