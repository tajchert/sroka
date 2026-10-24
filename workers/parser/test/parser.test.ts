import { env as rawEnv } from "cloudflare:workers";
import { PARSER_VERSION, r2Keys, urlHash, normalizeUrl, ParseResultSchema, type ParseJob, type ParseResult } from "@sroka/shared";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index.ts";
import { sweepOrphanedUserData } from "../src/gc.ts";
import type { ParserEnv } from "../src/env.ts";
import { addUser, migrateD1 } from "./d1.ts";

const base = rawEnv as unknown as ParserEnv;
const para = "The quick brown fox jumps over the lazy dog while reading a long and interesting article. ";
const PAGE = `<!doctype html><html lang="en"><head><title>Test Post</title><meta property="og:site_name" content="Example">
<meta property="og:image" content="https://example.com/lead.jpg"></head><body><article><h1>Test Post</h1>
<p>${para.repeat(10)}</p><p><img src="/a.png"></p><p>${para.repeat(10)}</p></article></body></html>`;

const ITEM = "0192f3c4-1111-7000-8000-0000000000aa";
const job = (over: Partial<ParseJob> = {}): ParseJob => ({ userId: "u1", itemId: ITEM, url: "https://example.com/post", parseGen: 3, ...over });

let marked: Array<{ userId: string; itemId: string; result: ParseResult }>;
let markFails = 0;
let wanted: boolean[] = [];
let markOk = true;
let imagesFail = false;
const fakeImages = {
  input: () => ({
    transform: ({ width }: { width: number }) => ({
      output: async () => {
        if (imagesFail) throw new Error("images down");
        const bytes = new Uint8Array([9, 9, width & 255, width >> 8]);
        return { image: () => new Blob([bytes]).stream(), contentType: () => "image/webp" };
      },
    }),
  }),
};

function mkEnv(): ParserEnv {
  return {
    ...base,
    IMAGES: fakeImages as never,
    LIBRARY: {
      getByName: (userId: string) => ({
        markParsed: async (itemId: string, result: ParseResult) => {
          if (markFails > 0) {
            markFails--;
            throw new Error("rpc down");
          }
          marked.push({ userId, itemId, result });
          return { ok: markOk };
        },
        parseWanted: async () => wanted.shift() ?? true,
        reemitContentRefs: async () => ({ refs: 0, pending: 0 }),
      }),
    },
  };
}

function msg(body: unknown, attempts = 1) {
  return { body, attempts, ack: vi.fn(), retry: vi.fn() };
}
async function run(m: ReturnType<typeof msg>[], queue = "sroka-parse", env = mkEnv()) {
  await worker.queue({ queue, messages: m } as never, env);
}

let fetchMock: ReturnType<typeof vi.spyOn>;
let fetched: string[];
function stubWeb(routes: Record<string, () => Response>) {
  fetchMock.mockImplementation((async (u: string) => {
    fetched.push(u);
    const r = routes[u];
    return r ? r() : new Response("nf", { status: 404 });
  }) as never);
}
const html = (b = PAGE) => new Response(b, { headers: { "content-type": "text/html; charset=utf-8" } });
const png = () => new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/png" } });

beforeAll(async () => {
  await migrateD1(base.DB);
});
const cacheableRows = async () => (await base.DB.prepare("SELECT COUNT(*) AS n FROM content WHERE cacheable = 1").first<{ n: number }>())!.n;
beforeEach(async () => {
  marked = [];
  markFails = 0;
  wanted = [];
  markOk = true;
  imagesFail = false;
  fetched = [];
  await base.DB.exec("DELETE FROM content");
  await base.DB.exec("DELETE FROM content_refs");
  await base.DB.exec("DELETE FROM gc_state");
  fetchMock = vi.spyOn(globalThis, "fetch");
});
afterEach(() => vi.restoreAllMocks());

describe("parser queue consumer", () => {
  it("fetches, extracts, writes public R2 objects + D1 row, and calls markParsed", async () => {
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    const m = msg(job());
    await run([m]);
    expect(m.ack).toHaveBeenCalled();
    expect(marked).toHaveLength(1);
    const { userId, itemId, result } = marked[0]!;
    expect([userId, itemId]).toEqual(["u1", ITEM]);
    expect(ParseResultSchema.parse(result)).toBeTruthy();
    expect(result).toMatchObject({ status: "ok", parseGen: 3, contentPrivate: false, siteName: "Example", lang: "en", leadImageKey: "thumb.webp", parserVersion: PARSER_VERSION });
    expect(result.wordCount).toBeGreaterThan(100);

    const dir = r2Keys.contentDir(result.contentId!);
    for (const f of ["article.html", "text.txt", "package.zip", "thumb.webp"]) expect(await base.CONTENT.head(dir + f), f).not.toBeNull();
    const art = await (await base.CONTENT.get(dir + "article.html"))!.text();
    expect(art).toMatch(/<img src="img\/[0-9a-f]{64}\.webp"/);
    const row = await base.DB.prepare("SELECT * FROM content").first<Record<string, unknown>>();
    expect(row).toMatchObject({ id: result.contentId, url_hash: await urlHash(normalizeUrl(job().url)), parser_version: PARSER_VERSION, status: "ok" });
  });

  it("reuses the shared cache for public content (no fetch), force bypasses it", async () => {
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job())]);
    const first = marked[0]!.result;
    fetched.length = 0;
    await run([msg(job({ itemId: "0192f3c4-1111-7000-8000-0000000000bb", userId: "u2", parseGen: 1 }))]);
    expect(fetched).toEqual([]);
    expect(marked[1]!.result).toMatchObject({ contentId: first.contentId, contentPrivate: false, parseGen: 1, title: first.title, leadImageKey: "thumb.webp" });
    await run([msg(job({ force: true }))]);
    expect(fetched.length).toBeGreaterThan(0);
    expect(marked[2]!.result.contentId).not.toBe(first.contentId);
  });

  it("ignores stale cache rows (old parser version / >7 days)", async () => {
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job())]);
    await base.DB.exec(`UPDATE content SET parsed_at = ${Date.now() - 8 * 86400_000}`);
    fetched.length = 0;
    await run([msg(job())]);
    expect(fetched).toContain("https://example.com/post");
    await base.DB.exec(`UPDATE content SET parser_version = ${PARSER_VERSION + 1}`);
    fetched.length = 0;
    await run([msg(job())]);
    expect(fetched).toContain("https://example.com/post");
  });

  it("parses captured raw HTML privately, never touching the network page or the shared cache", async () => {
    const rawKey = r2Keys.raw("u1", ITEM);
    const gz = await new Response(new Blob([PAGE]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer();
    await base.CONTENT.put(rawKey, gz);
    stubWeb({ "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job({ rawKey }))]);
    const { result } = marked[0]!;
    expect(result).toMatchObject({ status: "ok", contentPrivate: true });
    expect(fetched).not.toContain("https://example.com/post");
    expect(await base.CONTENT.head(r2Keys.contentDir(result.contentId!, "u1") + "article.html")).not.toBeNull();
    expect(await base.CONTENT.head(r2Keys.contentDir(result.contentId!) + "article.html")).toBeNull();
    expect((await base.DB.prepare("SELECT COUNT(*) AS n FROM content").first<{ n: number }>())!.n).toBe(0);
  });

  it("reads X / Twitter posts from the JSON API (short post = ok, never the page or a render; captures too)", async () => {
    const fx = {
      code: 200,
      status: { type: "status", id: "77", url: "https://x.com/ann/status/77", author: { screen_name: "ann", name: "Ann" }, raw_text: { text: "Short post.", facets: [] }, created_timestamp: 1792806105, likes: 3, media: {} },
      thread: [],
    };
    const api = () => new Response(JSON.stringify(fx), { headers: { "content-type": "application/json" } });
    stubWeb({ "https://api.fxtwitter.com/2/thread/77": api });
    await run([msg(job({ url: "https://x.com/ann/status/77" }))]);
    expect(marked[0]!.result).toMatchObject({ status: "ok", title: "Short post.", siteName: "X", author: "Ann (@ann)", contentPrivate: false });
    expect(fetched).toEqual(["https://api.fxtwitter.com/2/thread/77"]);
    const art = await (await base.CONTENT.get(r2Keys.contentDir(marked[0]!.result.contentId!) + "article.html"))!.text();
    expect(art).toContain("<p>Short post.</p>");

    marked = [];
    const rawKey = r2Keys.raw("u1", ITEM);
    const gz = await new Response(new Blob([PAGE]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer();
    await base.CONTENT.put(rawKey, gz);
    await run([msg(job({ url: "https://x.com/ann/status/77", rawKey }))]);
    expect(marked[0]!.result).toMatchObject({ status: "ok", title: "Short post.", contentPrivate: true });
  });

  it("decodes captured raw HTML as UTF-8 even if the page declares a legacy charset", async () => {
    const page = PAGE.replace("<title>", '<meta charset="iso-8859-2"><title>').replace("Test Post</h1>", "zolc \u017c\u00f3\u0142\u0107</h1>").replace(para.repeat(10), para.repeat(10) + " \u017c\u00f3\u0142\u0107 ");
    const rawKey = r2Keys.raw("u1", ITEM);
    const gz = await new Response(new Blob([page]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer();
    await base.CONTENT.put(rawKey, gz);
    stubWeb({ "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job({ rawKey }))]);
    const { result } = marked[0]!;
    const txt = await (await base.CONTENT.get(r2Keys.contentDir(result.contentId!, "u1") + "text.txt"))!.text();
    expect(txt).toContain("\u017c\u00f3\u0142\u0107");
  });

  it("marks a corrupt raw gzip as permanent raw_corrupt (no retry)", async () => {
    const rawKey = r2Keys.raw("u1", ITEM);
    await base.CONTENT.put(rawKey, new Uint8Array([1, 2, 3, 4, 5]));
    const m = msg(job({ rawKey }));
    await run([m]);
    expect(m.retry).not.toHaveBeenCalled();
    expect(marked[0]!.result).toMatchObject({ status: "failed", error: "raw_corrupt" });
  });

  const SHORT_CAPTURE = `<!doctype html><html><head><title>Consent</title></head><body><article><h1>Before you continue</h1><p>${para}</p></article></body></html>`;
  const putCapture = async (page: string) => {
    const rawKey = r2Keys.raw("u1", ITEM);
    await base.CONTENT.put(rawKey, await new Response(new Blob([page]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer());
    return rawKey;
  };

  it("a short capture falls back to a server fetch and keeps the longer text, still private", async () => {
    const rawKey = await putCapture(SHORT_CAPTURE);
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job({ rawKey }))]);
    const { result } = marked[0]!;
    expect(fetched).toContain("https://example.com/post");
    expect(result).toMatchObject({ status: "ok", contentPrivate: true, title: "Test Post" });
    expect(await base.CONTENT.head(r2Keys.contentDir(result.contentId!, "u1") + "article.html")).not.toBeNull();
    expect((await base.DB.prepare("SELECT COUNT(*) AS n FROM content").first<{ n: number }>())!.n).toBe(0);
  });

  it("a short capture keeps its own text when the server fetch fails or is shorter", async () => {
    const rawKey = await putCapture(SHORT_CAPTURE);
    stubWeb({});
    await run([msg(job({ rawKey }))]);
    expect(marked[0]!.result).toMatchObject({ status: "partial", contentPrivate: true, title: "Consent" });
  });

  it("a shared-cache hit touches last_used_at (GC grace); the parser no longer counts refs itself", async () => {
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job())]);
    const id = marked[0]!.result.contentId!;
    const row = async () => (await base.DB.prepare("SELECT ref_count AS rc, last_used_at AS lu, parsed_at AS pa FROM content WHERE id = ?1").bind(id).first<{ rc: number; lu: number; pa: number }>())!;
    expect((await row()).lu).toBe((await row()).pa);
    await base.DB.prepare("UPDATE content SET last_used_at = 5 WHERE id = ?1").bind(id).run();
    const before = Date.now();
    await run([msg(job())]);
    expect(marked[1]!.result.contentId).toBe(id);
    expect((await row()).lu).toBeGreaterThanOrEqual(before);
    expect((await row()).rc).toBe(0);
    // A row being garbage-collected is never served from the cache.
    await base.DB.prepare("UPDATE content SET gc_at = 1 WHERE id = ?1").bind(id).run();
    await run([msg(job())]);
    expect(marked[2]!.result.contentId).not.toBe(id);
  });

  it("fails permanently when the raw object is missing", async () => {
    await run([msg(job({ rawKey: "raw/u1/missing.html.gz" }))]);
    expect(marked[0]!.result).toMatchObject({ status: "failed", error: "raw_missing" });
    expect(marked[0]!.result.contentId).toBeUndefined();
  });

  it("falls back to original images when the Images binding fails", async () => {
    imagesFail = true;
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job())]);
    const { result } = marked[0]!;
    expect(result.status).toBe("ok");
    expect(result.leadImageKey).toBeUndefined();
    const list = await base.CONTENT.list({ prefix: r2Keys.contentDir(result.contentId!) + "img/" });
    expect(list.objects.map((o) => o.key)).toEqual([expect.stringMatching(/\.png$/)]);
  });

  it("marks permanent failures (404, non-html, extraction empty, blocked) as failed and acks", async () => {
    const cases: Array<[string, () => Response, string]> = [
      ["https://example.com/404", () => new Response("x", { status: 404 }), "http_404"],
      ["https://example.com/pdf", () => new Response("%PDF", { headers: { "content-type": "application/pdf" } }), "not_html"],
      ["https://example.com/empty", () => html("<html><body></body></html>"), "extract_failed"],
      ["http://127.0.0.1/admin", () => html(), "blocked_url"],
    ];
    for (const [url, r, err] of cases) {
      stubWeb({ [url]: r });
      const m = msg(job({ url }));
      await run([m]);
      expect(m.ack, url).toHaveBeenCalled();
      expect(m.retry, url).not.toHaveBeenCalled();
      expect(marked.at(-1)!.result, url).toMatchObject({ status: "failed", error: err });
    }
  });

  it("retries transient errors with backoff, then fails on the last attempt", async () => {
    stubWeb({ "https://example.com/post": () => new Response("x", { status: 503 }) });
    const m1 = msg(job(), 1);
    await run([m1]);
    expect(m1.retry).toHaveBeenCalledWith({ delaySeconds: 30 });
    expect(marked).toHaveLength(0);
    const m2 = msg(job(), 3);
    await run([m2]);
    expect(m2.retry).toHaveBeenCalledWith({ delaySeconds: 120 });
    const m4 = msg(job(), 4);
    await run([m4]);
    expect(m4.ack).toHaveBeenCalled();
    expect(marked[0]!.result).toMatchObject({ status: "failed", error: "http_503" });
  });

  it("retries when the markParsed RPC fails", async () => {
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    markFails = 1;
    const m = msg(job(), 1);
    await run([m]);
    expect(m.retry).toHaveBeenCalled();
    expect(m.ack).not.toHaveBeenCalled();
  });

  it("drops malformed messages", async () => {
    const m = msg({ nope: true });
    await run([m]);
    expect(m.ack).toHaveBeenCalled();
    expect(marked).toHaveLength(0);
  });

  it("DLQ consumer marks the item failed with the job's parseGen", async () => {
    const m = msg(job({ parseGen: 7 }));
    await run([m], "sroka-parse-dlq");
    expect(m.ack).toHaveBeenCalled();
    expect(marked[0]!.result).toEqual({
      status: "failed", parseGen: 7, contentPrivate: false, title: null, excerpt: null, siteName: null, author: null, lang: null,
      wordCount: null, readingMinutes: null, error: "parse_failed", parserVersion: PARSER_VERSION,
    });
  });

  it("skips superseded / already-done jobs before fetching, and before writing R2", async () => {
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    wanted = [false];
    const m = msg(job());
    await run([m]);
    expect(m.ack).toHaveBeenCalled();
    expect(fetched).toEqual([]);
    expect(marked).toEqual([]);
    // Superseded while extracting: nothing is written.
    wanted = [true, false];
    const m2 = msg(job());
    await run([m2]);
    expect(m2.ack).toHaveBeenCalled();
    expect(marked).toEqual([]);
    expect(await base.DB.prepare("SELECT COUNT(*) AS n FROM content").first<{ n: number }>()).toEqual({ n: 0 });
  });

  it("deletes the private content it wrote when markParsed rejects the result (e.g. account wiped)", async () => {
    const rawKey = r2Keys.raw("u9", ITEM);
    const gz = await new Response(new Blob([PAGE]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer();
    await base.CONTENT.put(rawKey, gz);
    stubWeb({ "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    markOk = false;
    await run([msg(job({ userId: "u9", rawKey }))]);
    const cid = marked[0]!.result.contentId!;
    expect((await base.CONTENT.list({ prefix: r2Keys.contentDir(cid, "u9") })).objects).toEqual([]);
  });

  it("never fills or reads the shared cache from a non-canonical fetch (tracking params echoed into the page)", async () => {
    const evil = "https://example.com/post?utm_campaign=Your+account+is+locked";
    stubWeb({ [evil]: () => html(), "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job({ url: evil }))]);
    expect(fetched[0]).toBe(evil);
    // Its public dir gets a (non-cacheable) row so the GC can collect it.
    expect(await cacheableRows()).toBe(0);
    expect(await base.DB.prepare("SELECT COUNT(*) AS n FROM content WHERE cacheable = 0").first<{ n: number }>()).toEqual({ n: 1 });
    // A canonical save fetches its own copy (and may be cached); the evil variant then doesn't read it.
    await run([msg(job({ itemId: "0192f3c4-1111-7000-8000-0000000000cc", parseGen: 1 }))]);
    expect(await cacheableRows()).toBe(1);
    fetched.length = 0;
    await run([msg(job({ url: evil, parseGen: 4 }))]);
    expect(fetched[0]).toBe(evil);
  });

  it("does not share 'partial' parses (bot walls, consent pages) through the cache", async () => {
    const thin = `<!doctype html><html><head><title>Access denied</title></head><body><article><p>${"Access denied. ".repeat(12)}</p></article></body></html>`;
    stubWeb({ "https://example.com/post": () => html(thin) });
    await run([msg(job())]);
    expect(marked[0]!.result.status).toBe("partial");
    expect(await cacheableRows()).toBe(0);
    const row = await base.DB.prepare("SELECT id, status, cacheable FROM content").first();
    expect(row).toEqual({ id: marked[0]!.result.contentId, status: "partial", cacheable: 0 });
  });

  it("weekly GC deletes R2 data of user ids that no longer exist", async () => {
    await addUser(base.DB, "alive");
    for (const k of ["private/alive/c1/a.html", "raw/alive/i.html.gz", "private/ghost/c1/a.html", "raw/ghost/i.html.gz", "uploads/ghost/x.csv"]) {
      await base.CONTENT.put(k, "x");
    }
    const r = await sweepOrphanedUserData(base);
    expect(r.deleted).toEqual(expect.arrayContaining(["private/ghost/", "raw/ghost/", "uploads/ghost/"]));
    expect(r.deleted.filter((p) => p.includes("/alive/"))).toEqual([]);
    expect(await base.CONTENT.head("private/alive/c1/a.html")).not.toBeNull();
    expect(await base.CONTENT.head("raw/alive/i.html.gz")).not.toBeNull();
    expect(await base.CONTENT.head("raw/ghost/i.html.gz")).toBeNull();
  });
});
