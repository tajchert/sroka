import { runInDurableObject } from "cloudflare:test";
import { LIMITS, PDF_FILE, r2Keys, uuidv7 } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { freshLibrary, testEnv } from "../do/helpers.ts";
import type { LibraryDO } from "../../src/library-do.ts";
import { makeApp } from "./app.ts";

/** A minimal "PDF": the marker is all the API checks. */
function pdfBytes(tag: string, pad = 0): Uint8Array {
  return new TextEncoder().encode(`%PDF-1.4\n% ${tag}\n${"x".repeat(pad)}\n%%EOF\n`);
}
const sha = async (b: Uint8Array) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", b))].map((x) => x.toString(16).padStart(2, "0")).join("");
const hdr = (b: Uint8Array) => ({ "content-type": "application/pdf", "content-length": String(b.byteLength) });
async function listPrefix(prefix: string): Promise<string[]> {
  return (await testEnv.CONTENT.list({ prefix })).objects.map((o) => o.key);
}

describe("POST /v1/items/pdf", () => {
  it("stores the file in R2, creates a pdf item and enqueues a pdf job", async () => {
    const { raw, call, sent, user, env } = makeApp();
    const bytes = pdfBytes("happy");
    const r = await raw("POST", "/v1/items/pdf?name=My%20Paper.pdf&tag=Science&tag=to-read&source=web", bytes, hdr(bytes));
    expect(r.status).toBe(202);
    expect(r.json.created).toBe(true);
    const item = r.json.item;
    expect(item).toMatchObject({
      kind: "pdf",
      fileName: "My Paper.pdf",
      fileSize: bytes.byteLength,
      title: "My Paper",
      siteName: "PDF",
      contentPrivate: true,
      parseStatus: "pending",
      source: "web",
      tags: ["Science", "to-read"],
    });
    expect(item.url).toBe(`${env.APP_ORIGIN}/pdf/${await sha(bytes)}`);
    expect(item.contentId).toBeTruthy();
    const key = r2Keys.contentDir(item.contentId, user) + PDF_FILE;
    const obj = await env.CONTENT.get(key);
    expect(obj!.httpMetadata?.contentType).toBe("application/pdf");
    expect(new Uint8Array(await obj!.arrayBuffer())).toEqual(bytes);
    expect(sent).toEqual([{ userId: user, itemId: item.id, url: item.url, parseGen: 1, pdf: { contentId: item.contentId } }]);

    // get / list / pull carry the new fields
    const got = await call("GET", `/v1/items/${item.id}`);
    expect(got.json.item).toMatchObject({ kind: "pdf", fileName: "My Paper.pdf", fileSize: bytes.byteLength });
    const list = await call("GET", "/v1/items?state=all");
    expect(list.json.items[0]).toMatchObject({ kind: "pdf", fileName: "My Paper.pdf" });
    const pull = await call("GET", "/v1/sync/pull?cursor=0");
    expect(pull.json.items[0]).toMatchObject({ kind: "pdf", fileName: "My Paper.pdf", fileSize: bytes.byteLength });
  });

  it("re-adds a duplicate (created:false) without keeping a second R2 object", async () => {
    const { raw, call, sent, user } = makeApp();
    const bytes = pdfBytes("dup");
    const first = await raw("POST", "/v1/items/pdf?name=a.pdf&tag=one", bytes, hdr(bytes));
    await call("PATCH", `/v1/items/${first.json.item.id}`, { status: "archived" });
    const again = await raw("POST", "/v1/items/pdf?name=renamed.pdf&tag=two", bytes, hdr(bytes));
    expect(again.status).toBe(202);
    expect(again.json.created).toBe(false);
    expect(again.json.item.id).toBe(first.json.item.id);
    expect(again.json.item.status).toBe("unread");
    expect(again.json.item.tags).toEqual(["one", "two"]);
    expect(again.json.item.fileName).toBe("a.pdf");
    expect(await listPrefix(`private/${user}/`)).toEqual([r2Keys.contentDir(first.json.item.contentId, user) + PDF_FILE]);
    expect(sent).toHaveLength(1);
  });

  it("415 for non-PDF bytes and foreign content types, nothing stays in R2", async () => {
    const { raw, user } = makeApp();
    const text = new TextEncoder().encode("hello, definitely not a pdf");
    const r = await raw("POST", "/v1/items/pdf?name=x.pdf", text, hdr(text));
    expect(r.status).toBe(415);
    expect(r.json.error).toBe("unsupported_media_type");
    // the marker must be within the first 1024 bytes
    const late = new Uint8Array(2000);
    late.set(new TextEncoder().encode("%PDF-1.4"), 1500);
    expect((await raw("POST", "/v1/items/pdf?name=x.pdf", late, hdr(late))).status).toBe(415);
    const b = pdfBytes("ct");
    expect((await raw("POST", "/v1/items/pdf?name=x.pdf", b, { ...hdr(b), "content-type": "text/html" })).status).toBe(415);
    expect(await listPrefix(`private/${user}/`)).toEqual([]);
  });

  it("413 over the size limit (declared), 411 without Content-Length, 400 without a name", async () => {
    const { raw, user } = makeApp();
    const b = pdfBytes("size");
    const big = await raw("POST", "/v1/items/pdf?name=x.pdf", b, { "content-type": "application/pdf", "content-length": String(LIMITS.maxPdfBytes + 1) });
    expect(big.status).toBe(413);
    expect(big.json.error).toBe("payload_too_large");
    const noLen = await raw("POST", "/v1/items/pdf?name=x.pdf", b, { "content-type": "application/pdf" });
    expect(noLen.status).toBe(411);
    expect(noLen.json.error).toBe("length_required");
    expect((await raw("POST", "/v1/items/pdf", b, hdr(b))).status).toBe(400);
    expect((await raw("POST", "/v1/items/pdf?name=x.pdf&source=bogus", b, hdr(b))).status).toBe(400);
    expect(await listPrefix(`private/${user}/`)).toEqual([]);
  });

  it("truncates long file names keeping .pdf", async () => {
    const { raw } = makeApp();
    const b = pdfBytes("long");
    const name = `${"n".repeat(400)}.pdf`;
    const r = await raw("POST", `/v1/items/pdf?name=${name}`, b, hdr(b));
    expect(r.json.item.fileName).toHaveLength(LIMITS.maxFileNameLength);
    expect(r.json.item.fileName.endsWith(".pdf")).toBe(true);
  });

  it("409 storage_full when the quota is exceeded; the object is removed", async () => {
    const { raw, user } = makeApp();
    const lib = testEnv.LIBRARY.getByName(user);
    // Seed a pdf item that already fills the quota (declared size only; no bytes needed).
    const seeded = await lib.addPdf("seed", {
      itemId: uuidv7(),
      url: "https://sroka.app/pdf/" + "a".repeat(64),
      title: "big",
      fileName: "big.pdf",
      fileSize: LIMITS.maxPdfStorageBytes,
      contentId: uuidv7(),
      tags: [],
      source: "api",
      at: Date.now(),
    });
    expect(seeded.ok).toBe(true);
    const b = pdfBytes("full");
    const r = await raw("POST", "/v1/items/pdf?name=x.pdf", b, hdr(b));
    expect(r.status).toBe(409);
    expect(r.json.error).toBe("storage_full");
    expect(await listPrefix(`private/${user}/`)).toEqual([]);
  });
});

describe("pdf items in the library", () => {
  it("refresh yields a pdf job, never deletes document.pdf", async () => {
    const { raw, call, sent, user, env } = makeApp();
    const b = pdfBytes("refresh");
    const up = await raw("POST", "/v1/items/pdf?name=r.pdf", b, hdr(b));
    const item = up.json.item;
    // finish the first parse, then refresh
    const lib = env.LIBRARY.getByName(user);
    const ok = await lib.markParsed(item.id, {
      status: "ok", parseGen: 1, contentId: item.contentId, contentPrivate: true, title: "Real Title", excerpt: "text", siteName: "PDF",
      author: null, lang: "en", wordCount: 10, readingMinutes: 1, parserVersion: 1,
    });
    expect(ok).toEqual({ ok: true });
    sent.length = 0;
    const r = await call("POST", `/v1/items/${item.id}/refresh`);
    expect(r.status).toBe(202);
    expect(sent).toEqual([{ userId: user, itemId: item.id, url: item.url, parseGen: 2, force: true, pdf: { contentId: item.contentId } }]);
    expect(await env.CONTENT.head(r2Keys.contentDir(item.contentId, user) + PDF_FILE)).not.toBeNull();
    const got = await call("GET", `/v1/items/${item.id}`);
    expect(got.json.item).toMatchObject({ title: "Real Title", contentId: item.contentId, kind: "pdf", fileName: "r.pdf" });
  });

  it("markParsed keeps the file for the same content id, refuses a different one, and a failed result keeps it readable", async () => {
    const { raw, user, env } = makeApp();
    const b = pdfBytes("mark");
    const item = (await raw("POST", "/v1/items/pdf?name=m.pdf", b, hdr(b))).json.item;
    const key = r2Keys.contentDir(item.contentId, user) + PDF_FILE;
    const lib = env.LIBRARY.getByName(user);
    const base = { parseGen: 1, title: null, excerpt: null, siteName: "PDF", author: null, lang: null, wordCount: null, readingMinutes: null, parserVersion: 1 };
    expect(await lib.markParsed(item.id, { ...base, status: "ok", contentId: uuidv7(), contentPrivate: true })).toEqual({ ok: false });
    expect(await lib.markParsed(item.id, { ...base, status: "ok", contentId: item.contentId, contentPrivate: false })).toEqual({ ok: false });
    expect(await env.CONTENT.head(key)).not.toBeNull();
    expect(await lib.markParsed(item.id, { ...base, status: "ok", contentId: item.contentId, contentPrivate: true, error: "pdf_no_text" })).toEqual({ ok: true });
    expect(await env.CONTENT.head(key)).not.toBeNull();
    const after = await lib.getItem(item.id);
    expect(after).toMatchObject({ parseStatus: "ok", parseError: "pdf_no_text", title: "m", contentId: item.contentId });

    // a failed result (e.g. DLQ) after a refresh leaves content alone
    await lib.applyRest("d", [{ opId: uuidv7(), at: Date.now(), type: "item.refresh", itemId: item.id }], { itemId: item.id });
    expect(await lib.markParsed(item.id, { ...base, parseGen: 2, status: "failed", contentPrivate: false, error: "boom" })).toEqual({ ok: true });
    expect(await env.CONTENT.head(key)).not.toBeNull();
    expect((await lib.getItem(item.id))!.contentId).toBe(item.contentId);
  });

  it("the stale-pending sweep keeps the pdf marker", async () => {
    const { userId, lib } = freshLibrary("pdfsweep");
    const contentId = uuidv7();
    const r = await lib.addPdf("d", {
      itemId: uuidv7(), url: "https://sroka.app/pdf/" + "b".repeat(64), title: "s", fileName: "s.pdf", fileSize: 10, contentId, tags: [], source: "api", at: Date.now(),
    });
    expect(r.ok).toBe(true);
    const jobs = await runInDurableObject(lib, (inst: LibraryDO) =>
      (inst as unknown as { store: { requeueStalePending(a: number, b: number, c: number): unknown[] } }).store.requeueStalePending(Date.now() + 3_600_000, 10, Date.now()),
    );
    expect(jobs).toEqual([{ userId, itemId: r.ok ? r.item.id : "", url: "https://sroka.app/pdf/" + "b".repeat(64), parseGen: 1, pdf: { contentId } }]);
  });

  it("deleting the item removes document.pdf", async () => {
    const { raw, call, user, env } = makeApp();
    const b = pdfBytes("del");
    const item = (await raw("POST", "/v1/items/pdf?name=d.pdf", b, hdr(b))).json.item;
    expect((await call("DELETE", `/v1/items/${item.id}`)).status).toBe(204);
    expect(await listPrefix(`private/${user}/`)).toEqual([]);
    void env;
  });

  it("GET /content returns documentUrl for pdfs, null for articles", async () => {
    const { raw, call } = makeApp();
    const b = pdfBytes("content");
    const item = (await raw("POST", "/v1/items/pdf?name=c.pdf", b, hdr(b))).json.item;
    const urls = (await call("GET", `/v1/items/${item.id}/content`)).json;
    expect(urls.documentUrl).toMatch(/\/document\.pdf$/);
    expect(urls.articleUrl).toMatch(/\/article\.html$/);
    expect(urls.packageUrl).toMatch(/\/package\.zip$/);
  });
});
