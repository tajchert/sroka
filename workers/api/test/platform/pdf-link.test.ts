import { describe, expect, it } from "vitest";
import { APP, call, signIn, testEnv } from "./helpers.ts";

const bytes = new TextEncoder().encode("%PDF-1.4\n% link test\n%%EOF\n");
const sha = async () =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((x) => x.toString(16).padStart(2, "0")).join("");

describe("GET /pdf/:sha256", () => {
  it("redirects a signed-in owner to the signed document URL, sends others to /app/, 404 for unknown", async () => {
    const { token, cookie } = await signIn("pdf-link@example.com");
    const up = await call("/v1/items/pdf?name=l.pdf", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/pdf", "content-length": String(bytes.byteLength) },
      body: bytes,
    });
    expect(up.status).toBe(202);
    const hash = await sha();

    const ok = await call(`/pdf/${hash}`, { headers: { cookie }, redirect: "manual" });
    expect(ok.status).toBe(302);
    const loc = ok.headers.get("location")!;
    expect(loc.startsWith(testEnv.CONTENT_ORIGIN)).toBe(true);
    expect(loc).toMatch(/\/document\.pdf$/);
    // the redirect target is served
    const file = await call(new URL(loc).pathname, {}, testEnv.CONTENT_ORIGIN);
    expect(file.status).toBe(200);
    expect(file.headers.get("content-type")).toBe("application/pdf");

    const anon = await call(`/pdf/${hash}`, { redirect: "manual" });
    expect(anon.status).toBe(302);
    expect(anon.headers.get("location")).toBe("/app/");

    const other = await signIn("pdf-link-other@example.com");
    expect((await call(`/pdf/${hash}`, { headers: { cookie: other.cookie }, redirect: "manual" })).status).toBe(404);
    expect((await call(`/pdf/${"0".repeat(64)}`, { headers: { cookie }, redirect: "manual" })).status).toBe(404);
    expect((await call("/pdf/notasha", { headers: { cookie }, redirect: "manual" })).status).toBe(404);
    expect(APP).toBeTruthy();
  });
});
