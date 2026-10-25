import { runInDurableObject } from "cloudflare:test";
import { LIMITS, PDF_FILE, r2Keys, uuidv7 } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { freshLibrary, testEnv } from "../do/helpers.ts";
import type { LibraryDO } from "../../src/library-do.ts";
import { cleanFileName } from "../../src/routes/items.ts";
import type { Env } from "../../src/env.ts";
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

const sqlRows = async (user: string, q: string): Promise<Record<string, unknown>[]> =>
  runInDurableObject(testEnv.LIBRARY.getByName(user), (_i: LibraryDO, state) => state.storage.sql.exec(q).toArray() as Record<string, unknown>[]);

describe("review fixes", () => {
  it("keeps the object when the addPdf outcome is unknown (DO committed, RPC failed)", async () => {
    const real = testEnv.LIBRARY;
    const flaky = {
      getByName: (n: string) => {
        const stub = real.getByName(n);
        return new Proxy(stub, {
          get: (t, p) =>
            p === "addPdf"
              ? async (...a: unknown[]) => {
                  await (t as any).addPdf(...a);
                  throw new Error("rpc wire failure");
                }
              : (...a: unknown[]) => (t as any)[p](...a),
        });
      },
    } as unknown as Env["LIBRARY"];
    const { raw, call, user, env } = makeApp({ LIBRARY: flaky });
    const b = pdfBytes("unknown");
    const r = await raw("POST", "/v1/items/pdf?name=u.pdf", b, hdr(b));
    expect(r.status).toBe(500);
    const items = (await call("GET", "/v1/items?state=all")).json.items;
    expect(items).toHaveLength(1);
    expect(await env.CONTENT.head(r2Keys.contentDir(items[0].contentId, user) + PDF_FILE)).not.toBeNull();
  });

  it("a duplicate whose original is gone adopts the new copy (seq bumped, new pdf job)", async () => {
    const { raw, call, sent, user, env } = makeApp();
    const b = pdfBytes("lost");
    const first = (await raw("POST", "/v1/items/pdf?name=a.pdf", b, hdr(b))).json.item;
    const oldKey = r2Keys.contentDir(first.contentId, user) + PDF_FILE;
    await env.CONTENT.delete(oldKey);
    await env.CONTENT.put(r2Keys.contentDir(first.contentId, user) + "text.txt", "old text");
    sent.length = 0;
    const again = await raw("POST", "/v1/items/pdf?name=a.pdf", b, hdr(b));
    expect(again.status).toBe(202);
    expect(again.json.created).toBe(false);
    const item = again.json.item;
    expect(item.id).toBe(first.id);
    expect(item.contentId).not.toBe(first.contentId);
    expect(item.seq).toBeGreaterThan(first.seq);
    const newKey = r2Keys.contentDir(item.contentId, user) + PDF_FILE;
    expect(new Uint8Array(await (await env.CONTENT.get(newKey))!.arrayBuffer())).toEqual(b);
    expect(await listPrefix(`private/${user}/`)).toEqual([newKey]); // old dir (stale text.txt) removed
    expect(sent).toEqual([{ userId: user, itemId: first.id, url: first.url, parseGen: 2, pdf: { contentId: item.contentId } }]);
    expect((await call("GET", `/v1/items/${first.id}`)).json.item.contentId).toBe(item.contentId);
    expect(await sqlRows(user, "SELECT * FROM pdf_uploads")).toEqual([]);
  });

  it("item.add of a /pdf/{sha} url is rejected unless the pdf item exists", async () => {
    const { raw, call, env } = makeApp();
    const b = pdfBytes("junk");
    const url = `${env.APP_ORIGIN}/pdf/${await sha(b)}`;
    const rest = await call("POST", "/v1/items", { url });
    expect(rest.status).toBe(400);
    expect(rest.json.error).toBe("invalid_url");
    const op = { opId: uuidv7(), at: Date.now(), type: "item.add", itemId: uuidv7(), url };
    const push = await call("POST", "/v1/sync/push", { deviceId: "dev", ops: [op] });
    expect(push.json.rejected).toEqual([{ opId: op.opId, reason: "invalid_url" }]);
    // the real upload still works, and afterwards the same add is a normal duplicate re-add
    const up = await raw("POST", "/v1/items/pdf?name=real.pdf", b, hdr(b));
    expect(up.json.created).toBe(true);
    const dup = await call("POST", "/v1/items", { url });
    expect(dup.status).toBeLessThan(300);
    expect(dup.json.item.id).toBe(up.json.item.id);
    // other hosts / shapes are ordinary urls
    expect((await call("POST", "/v1/items", { url: `https://example.com/pdf/${await sha(b)}` })).status).toBeLessThan(300);
    expect((await call("POST", "/v1/items", { url: `${env.APP_ORIGIN}/pdf/abc` })).status).toBeLessThan(300);
  });

  it("reservations: removed on commit; the sweep reclaims unreferenced old uploads only", async () => {
    const { raw, user, env } = makeApp();
    const b = pdfBytes("res");
    const item = (await raw("POST", "/v1/items/pdf?name=r.pdf", b, hdr(b))).json.item;
    expect(await sqlRows(user, "SELECT * FROM pdf_uploads")).toEqual([]);
    const lib = env.LIBRARY.getByName(user);
    const orphan = uuidv7();
    const orphanKey = r2Keys.contentDir(orphan, user) + PDF_FILE;
    await lib.reservePdfUpload(orphan);
    await env.CONTENT.put(orphanKey, pdfBytes("orphan"));
    await lib.reservePdfUpload(item.contentId); // stale row for a referenced content id
    const fresh = uuidv7();
    await lib.reservePdfUpload(fresh);
    await env.CONTENT.put(r2Keys.contentDir(fresh, user) + PDF_FILE, pdfBytes("fresh"));
    // not old enough yet
    expect(await lib.sweepPdfUploads(Date.now() + 30 * 60_000)).toBe(0);
    expect(await env.CONTENT.head(orphanKey)).not.toBeNull();
    // 2 hours later
    expect(await lib.sweepPdfUploads(Date.now() + 2 * 3_600_000)).toBe(2);
    expect(await env.CONTENT.head(orphanKey)).toBeNull();
    expect(await env.CONTENT.head(r2Keys.contentDir(item.contentId, user) + PDF_FILE)).not.toBeNull();
    expect(await sqlRows(user, "SELECT * FROM pdf_uploads")).toEqual([]);
  });

  it("a rejected upload keeps no object but leaves a reservation the alarm drops", async () => {
    const { raw, user } = makeApp();
    const b = new TextEncoder().encode("not a pdf at all");
    expect((await raw("POST", "/v1/items/pdf?name=x.pdf", b, hdr(b))).status).toBe(415);
    expect(await listPrefix(`private/${user}/`)).toEqual([]);
    expect(await sqlRows(user, "SELECT * FROM pdf_uploads")).toHaveLength(1);
  });

  it("cleanFileName", () => {
    expect(cleanFileName("a/b\\c:d.pdf")).toBe("a_b_c_d.pdf");
    expect(cleanFileName("\u202Efdp.exe\u200B.pdf\u0007")).toBe("fdp.exe.pdf");
    expect(cleanFileName(" \u200B ")).toBe("document.pdf");
    const max = LIMITS.maxFileNameLength;
    // an emoji straddling the cut is dropped whole, .pdf is kept
    const n = cleanFileName("a" + "\u{1F600}".repeat(max) + ".pdf");
    expect(n.length).toBeLessThanOrEqual(max);
    expect(n.endsWith(".pdf")).toBe(true);
    expect(n).not.toMatch(/[\ud800-\udbff](?![\udc00-\udfff])/);
    expect(n).not.toMatch(/(?<![\ud800-\udbff])[\udc00-\udfff]/);
    expect(cleanFileName("n".repeat(max + 5))).toHaveLength(max);
  });

  it("a body longer than Content-Length fails cleanly with no object left", async () => {
    const { raw, user } = makeApp();
    const b = pdfBytes("over", 3000);
    const r = await raw("POST", "/v1/items/pdf?name=x.pdf", b, { "content-type": "application/pdf", "content-length": "1500" });
    expect(r.status).toBe(400);
    expect(await listPrefix(`private/${user}/`)).toEqual([]);
  });
});

describe("LibraryDO.setPdfThumbnail", () => {
  async function pdfItem(tag: string) {
    const { raw, call, user, env } = makeApp();
    const b = pdfBytes(tag);
    const item = (await raw("POST", `/v1/items/pdf?name=${tag}.pdf`, b, hdr(b))).json.item;
    return { call, user, env, item, lib: env.LIBRARY.getByName(user) };
  }

  it("sets leadImageKey, signs leadImageUrl and makes the item sync-visible", async () => {
    const { call, item, lib } = await pdfItem("thumb-set");
    const cursor = (await call("GET", "/v1/sync/pull?cursor=0")).json.cursor;
    const r = await lib.setPdfThumbnail(item.id, item.contentId, "thumb.webp");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.previousKey).toBeNull();
    expect(r.item.leadImageKey).toBe("thumb.webp");
    expect(r.item.leadImageUrl).toMatch(/\/thumb\.webp$/);
    expect((await lib.getItem(item.id))!.leadImageKey).toBe("thumb.webp");
    const pull = await call("GET", `/v1/sync/pull?cursor=${cursor}`);
    expect(pull.json.items.map((i: { id: string }) => i.id)).toContain(item.id);
  });

  it("returns the previous key when replacing", async () => {
    const { item, lib } = await pdfItem("thumb-replace");
    await lib.setPdfThumbnail(item.id, item.contentId, "thumb.jpg");
    const r = await lib.setPdfThumbnail(item.id, item.contentId, "thumb.webp");
    expect(r).toMatchObject({ ok: true, previousKey: "thumb.jpg" });
  });

  it("refuses an article, a deleted item, a wrong content id and an unknown id", async () => {
    const { call, item, lib } = await pdfItem("thumb-refuse");
    expect(await lib.setPdfThumbnail(item.id, uuidv7(), "thumb.webp")).toEqual({ ok: false });
    expect(await lib.setPdfThumbnail(uuidv7(), item.contentId, "thumb.webp")).toEqual({ ok: false });
    const art = await call("POST", "/v1/items", { url: "https://example.com/a" });
    const artId = art.json.item.id;
    expect(await lib.setPdfThumbnail(artId, item.contentId, "thumb.webp")).toEqual({ ok: false });
    expect((await call("DELETE", `/v1/items/${item.id}`)).status).toBe(204);
    expect(await lib.setPdfThumbnail(item.id, item.contentId, "thumb.webp")).toEqual({ ok: false });
  });

  it("a later pdf parse result keeps the uploaded thumbnail", async () => {
    const { item, lib } = await pdfItem("thumb-parse");
    await lib.setPdfThumbnail(item.id, item.contentId, "thumb.webp");
    const ok = await lib.markParsed(item.id, {
      status: "ok", parseGen: 1, contentId: item.contentId, contentPrivate: true, title: null, excerpt: "x", siteName: "PDF",
      author: null, lang: null, wordCount: 1, readingMinutes: 1, parserVersion: 1,
    });
    expect(ok).toEqual({ ok: true });
    expect((await lib.getItem(item.id))!.leadImageKey).toBe("thumb.webp");
  });
});

describe("PUT /v1/items/:id/thumbnail", () => {
  const webp = (n = 64) => {
    const b = new Uint8Array(n);
    b.set(new TextEncoder().encode("RIFF"), 0);
    b.set(new TextEncoder().encode("WEBP"), 8);
    return b;
  };
  const jpeg = (n = 64) => {
    const b = new Uint8Array(n);
    b.set([0xff, 0xd8, 0xff, 0xe0], 0);
    return b;
  };
  const ih = (b: Uint8Array, type: string) => ({ "content-type": type, "content-length": String(b.byteLength) });

  async function setup(tag: string, envOverride: Partial<Env> = {}) {
    const app = makeApp(envOverride);
    const b = pdfBytes(tag);
    const item = (await app.raw("POST", `/v1/items/pdf?name=${tag}.pdf`, b, hdr(b))).json.item;
    return { ...app, item, dir: r2Keys.contentDir(item.contentId, app.user) };
  }

  it("stores a webp preview and returns the item with a signed leadImageUrl", async () => {
    const { raw, call, env, item, dir } = await setup("put-webp");
    const body = webp();
    const r = await raw("PUT", `/v1/items/${item.id}/thumbnail`, body, ih(body, "image/webp"));
    expect(r.status).toBe(200);
    expect(r.json.item).toMatchObject({ id: item.id, leadImageKey: "thumb.webp" });
    expect(r.json.item.leadImageUrl).toMatch(/\/thumb\.webp$/);
    const obj = await env.CONTENT.get(dir + "thumb.webp");
    expect(obj!.httpMetadata?.contentType).toBe("image/webp");
    expect(new Uint8Array(await obj!.arrayBuffer())).toEqual(body);
    expect((await call("GET", `/v1/items/${item.id}`)).json.item.leadImageKey).toBe("thumb.webp");
  });

  it("jpeg goes to thumb.jpg; switching back to webp deletes the old object", async () => {
    const { raw, item, dir } = await setup("put-jpeg");
    const j = jpeg();
    const r1 = await raw("PUT", `/v1/items/${item.id}/thumbnail`, j, ih(j, "image/jpeg"));
    expect(r1.json.item.leadImageKey).toBe("thumb.jpg");
    const w = webp();
    const r2 = await raw("PUT", `/v1/items/${item.id}/thumbnail`, w, ih(w, "image/webp"));
    expect(r2.json.item.leadImageKey).toBe("thumb.webp");
    expect((await listPrefix(dir)).sort()).toEqual([dir + PDF_FILE, dir + "thumb.webp"].sort());
  });

  it("411 without Content-Length, 413 over 512 KiB, 415 for png or mismatched bytes", async () => {
    const { raw, item, dir } = await setup("put-bad");
    const path = `/v1/items/${item.id}/thumbnail`;
    expect((await raw("PUT", path, webp(), { "content-type": "image/webp" })).status).toBe(411);
    const big = webp(LIMITS.maxThumbnailBytes + 1);
    expect((await raw("PUT", path, big, ih(big, "image/webp"))).status).toBe(413);
    const w = webp();
    expect((await raw("PUT", path, w, ih(w, "image/png"))).json.error).toBe("unsupported_media_type");
    const j = jpeg();
    expect((await raw("PUT", path, j, ih(j, "image/webp"))).status).toBe(415);
    expect(await listPrefix(dir)).toEqual([dir + PDF_FILE]);
  });

  it("404 for an unknown item, 409 not_pdf for an article", async () => {
    const { raw, call } = await setup("put-404");
    const w = webp();
    expect((await raw("PUT", `/v1/items/${uuidv7()}/thumbnail`, w, ih(w, "image/webp"))).status).toBe(404);
    const art = (await call("POST", "/v1/items", { url: "https://example.com/thumb-art" })).json.item;
    const r = await raw("PUT", `/v1/items/${art.id}/thumbnail`, w, ih(w, "image/webp"));
    expect(r.status).toBe(409);
    expect(r.json.error).toBe("not_pdf");
  });

  it("an item deleted before the commit → 404 and no preview left in R2", async () => {
    const real = testEnv.LIBRARY;
    const racing = {
      getByName: (n: string) => {
        const stub = real.getByName(n);
        return new Proxy(stub, {
          get: (t, p) =>
            p === "setPdfThumbnail"
              ? async (id: string, ...rest: unknown[]) => {
                  await (t as any).applyRest("d", [{ opId: uuidv7(), at: Date.now(), type: "item.delete", itemId: id }], { itemId: id });
                  return (t as any).setPdfThumbnail(id, ...rest);
                }
              : (...a: unknown[]) => (t as any)[p](...a),
        });
      },
    } as unknown as Env["LIBRARY"];
    const { raw, item, user } = await setup("put-race", { LIBRARY: racing });
    const w = webp();
    expect((await raw("PUT", `/v1/items/${item.id}/thumbnail`, w, ih(w, "image/webp"))).status).toBe(404);
    expect(await listPrefix(`private/${user}/`)).toEqual([]);
  });
});
