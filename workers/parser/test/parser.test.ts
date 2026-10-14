import { env as rawEnv } from "cloudflare:workers";
import { PARSER_VERSION, r2Keys, urlHash, normalizeUrl, ParseResultSchema, type ParseJob, type ParseResult } from "@sroka/shared";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index.ts";
import type { ParserEnv } from "../src/env.ts";

const base = rawEnv as unknown as ParserEnv;
const para = "The quick brown fox jumps over the lazy dog while reading a long and interesting article. ";
const PAGE = `<!doctype html><html lang="en"><head><title>Test Post</title><meta property="og:site_name" content="Example">
<meta property="og:image" content="https://example.com/lead.jpg"></head><body><article><h1>Test Post</h1>
<p>${para.repeat(10)}</p><p><img src="/a.png"></p><p>${para.repeat(10)}</p></article></body></html>`;

const ITEM = "0192f3c4-1111-7000-8000-0000000000aa";
const job = (over: Partial<ParseJob> = {}): ParseJob => ({ userId: "u1", itemId: ITEM, url: "https://example.com/post", parseGen: 3, ...over });

let marked: Array<{ userId: string; itemId: string; result: ParseResult }>;
let markFails = 0;
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
          return { ok: true };
        },
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
  await base.DB.exec(
    "CREATE TABLE IF NOT EXISTS content (id TEXT PRIMARY KEY, url_hash TEXT NOT NULL, canonical_url TEXT NOT NULL, parser_version INTEGER NOT NULL, status TEXT NOT NULL, title TEXT, word_count INTEGER, lang TEXT, bytes INTEGER, ref_count INTEGER DEFAULT 0, parsed_at INTEGER NOT NULL);",
  );
});
beforeEach(async () => {
  marked = [];
  markFails = 0;
  imagesFail = false;
  fetched = [];
  await base.DB.exec("DELETE FROM content");
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

  it("increments ref_count after markParsed ok, on fresh parse and cache hit; not for private", async () => {
    stubWeb({ "https://example.com/post": () => html(), "https://example.com/a.png": png, "https://example.com/lead.jpg": png });
    await run([msg(job())]);
    const id = marked[0]!.result.contentId!;
    const rc = async () => (await base.DB.prepare("SELECT ref_count AS n FROM content WHERE id = ?1").bind(id).first<{ n: number }>())!.n;
    expect(await rc()).toBe(1);
    await run([msg(job())]);
    expect(marked[1]!.result.contentId).toBe(id);
    expect(await rc()).toBe(2);
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
});
