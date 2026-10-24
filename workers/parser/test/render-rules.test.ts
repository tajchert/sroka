// Browser Run fallback, KV site rules, parse_attempts + metric layout (decisions D10).
import { env as rawEnv } from "cloudflare:workers";
import { BROWSER_UA } from "@sroka/extractor";
import { hashId, normalizeUrl, PARSER_VERSION, r2Keys, siteRuleKey, type ParseJob, type ParseResult } from "@sroka/shared";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index.ts";
import type { ParserEnv } from "../src/env.ts";
import { purgeParseAnalytics } from "../src/gc.ts";
import { clearSiteRuleCache, loadSiteRule, RULE_CACHE_TTL_MS } from "../src/site-rules.ts";
import { migrateD1 } from "./d1.ts";

const base = rawEnv as unknown as ParserEnv;
const para = "The quick brown fox jumps over the lazy dog while reading a long and interesting article. ";
const LONG = `<!doctype html><html lang="en"><head><title>Long</title></head><body>
<div class="promo">PROMO ${para.repeat(2)}</div><article><h1>Long</h1><p>${para.repeat(10)}</p><p class="ad">BUY NOW ${para}</p><p>${para.repeat(10)}</p></article>
<section id="real"><p>REAL ${para.repeat(8)}</p></section></body></html>`;
const SHORT = `<!doctype html><html><head><title>Short</title></head><body><article><p>${para.repeat(3)}</p></article></body></html>`;
const CHALLENGE = `<!doctype html><html><head><title>Just a moment...</title></head><body><script src="/cdn-cgi/challenge-platform/h/b/x.js"></script></body></html>`;
const RENDERED = `<!doctype html><html><head><title>Rendered</title></head><body><article><h1>Rendered</h1><p>RENDERED ${para.repeat(12)}</p></article></body></html>`;

const URL1 = "https://example.com/post";
const ITEM = "0192f3c4-2222-7000-8000-0000000000aa";
const job = (over: Partial<ParseJob> = {}): ParseJob => ({ userId: "u1", itemId: ITEM, url: URL1, parseGen: 1, ...over });

let marked: ParseResult[];
let fetched: { url: string; ua: string | null }[];
let routes: Record<string, () => Response>;
let quickAction: ReturnType<typeof vi.fn>;
let renderHtml: string;
let metrics: { blobs?: (string | null)[]; doubles?: number[]; indexes?: (string | null)[] }[];

const htmlRes = (b: string, status = 200) => new Response(b, { status, headers: { "content-type": "text/html; charset=utf-8" } });

function mkEnv(over: Partial<ParserEnv> = {}): ParserEnv {
  return {
    ...base,
    BROWSER_RENDER_ENABLED: "true",
    BROWSER: { quickAction } as never,
    METRICS: { writeDataPoint: (p: (typeof metrics)[number]) => metrics.push(p) } as never,
    IMAGES: {} as never,
    LIBRARY: {
      getByName: () => ({
        markParsed: async (_itemId: string, result: ParseResult) => {
          marked.push(result);
          return { ok: true };
        },
        parseWanted: async () => true,
        reemitContentRefs: async () => ({ refs: 0, pending: 0 }),
      }),
    },
    ...over,
  };
}
function msg(body: unknown, attempts = 1) {
  return { body, attempts, ack: vi.fn(), retry: vi.fn() };
}
async function run(m: ReturnType<typeof msg>, env = mkEnv(), queue = "sroka-parse") {
  await worker.queue({ queue, messages: [m] } as never, env);
}
const attempts = async () => (await base.DB.prepare("SELECT * FROM parse_attempts ORDER BY created_at, id").all<Record<string, unknown>>()).results;
const putRule = (host: string, rule: unknown) => base.CONFIG.put(siteRuleKey(host), typeof rule === "string" ? rule : JSON.stringify(rule));
const text = async (r: ParseResult) => (await base.CONTENT.get(r2Keys.contentDir(r.contentId!, r.contentPrivate ? "u1" : null) + "text.txt"))!.text();

beforeAll(async () => {
  await migrateD1(base.DB);
});
beforeEach(async () => {
  marked = [];
  fetched = [];
  metrics = [];
  routes = { [URL1]: () => htmlRes(LONG) };
  renderHtml = RENDERED;
  quickAction = vi.fn(async (_action: string, o: { url: string }) =>
    Response.json({ success: true, result: renderHtml, meta: { status: 200, title: "Rendered", finalUrl: o.url } }),
  );
  clearSiteRuleCache();
  for (const k of (await base.CONFIG.list()).keys) await base.CONFIG.delete(k.name);
  await base.DB.exec("DELETE FROM content");
  await base.DB.exec("DELETE FROM parse_attempts");
  await base.DB.exec("DELETE FROM render_budget");
  vi.spyOn(globalThis, "fetch").mockImplementation((async (u: string, init?: RequestInit) => {
    fetched.push({ url: u, ua: new Headers(init?.headers).get("user-agent") });
    const r = routes[u];
    return r ? r() : new Response("nf", { status: 404 });
  }) as never);
});
afterEach(() => vi.restoreAllMocks());

describe("Browser Run fallback", () => {
  it("renders on a 403 bot wall: ok via render, attempt row + metric layout", async () => {
    routes[URL1] = () => htmlRes("denied", 403);
    await run(msg(job()));
    expect(quickAction).toHaveBeenCalledTimes(1);
    const [action, opts] = quickAction.mock.calls[0]!;
    expect(action).toBe("content");
    expect(opts).toMatchObject({ url: URL1, rejectResourceTypes: ["image", "media", "font"] });
    expect(opts.userAgent).toBeUndefined();
    expect(marked[0]).toMatchObject({ status: "ok" });
    expect(await text(marked[0]!)).toMatch(/^Rendered\n\nRENDERED|RENDERED/);

    const [row] = await attempts();
    expect(row).toMatchObject({
      user_hash: await hashId("u1", 16),
      item_id: ITEM,
      domain: "example.com",
      url: normalizeUrl(URL1),
      status: "ok",
      error_code: null,
      method: "render",
      fallback_outcome: "ok",
      http_status: 200,
      attempt: 1,
      parser_version: PARSER_VERSION,
      rule_applied: 0,
    });
    expect(row!.text_chars).toBeGreaterThan(500);
    expect(row!.word_count).toBeGreaterThan(100);
    expect(row!.render_ms).toBeTypeOf("number");

    expect(metrics).toHaveLength(1);
    const p = metrics[0]!;
    expect(p.blobs).toEqual(["parse", "example.com", "ok", "", "fetch", "miss", "render", "ok", "0"]);
    expect(p.doubles).toHaveLength(6);
    expect(p.doubles![4]).toBe(row!.text_chars);
    expect(p.doubles![5]).toBe(1);
    expect(p.indexes).toEqual(["example.com"]);
  });

  it("renders on a 200 challenge page and on short text", async () => {
    routes[URL1] = () => htmlRes(CHALLENGE);
    await run(msg(job()));
    expect(quickAction).toHaveBeenCalledTimes(1);
    expect(marked[0]).toMatchObject({ status: "ok" });

    routes[URL1] = () => htmlRes(SHORT);
    await run(msg(job({ force: true })));
    expect(quickAction).toHaveBeenCalledTimes(2);
    expect(marked[1]).toMatchObject({ status: "ok" });
    expect((await attempts()).map((r) => r.method)).toEqual(["render", "render"]);
  });

  it("does not render a good plain fetch", async () => {
    await run(msg(job()));
    expect(quickAction).not.toHaveBeenCalled();
    expect((await attempts())[0]).toMatchObject({ method: "fetch", fallback_outcome: "none", status: "ok", http_status: 200 });
  });

  it("never renders captured HTML; captured rows have url NULL", async () => {
    const rawKey = r2Keys.raw("u1", ITEM);
    const gz = await new Response(new Blob([SHORT]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer();
    await base.CONTENT.put(rawKey, gz);
    routes[URL1] = () => htmlRes("gone", 404); // the plain-fetch fallback for short captures fails too
    await run(msg(job({ rawKey })));
    expect(quickAction).not.toHaveBeenCalled();
    expect(marked[0]).toMatchObject({ status: "partial", contentPrivate: true });
    expect((await attempts())[0]).toMatchObject({ method: "capture", fallback_outcome: "failed", error_detail: "fetch_http_404", url: null, status: "partial" });
  });

  it("over budget: no render, keeps the failure, records budget", async () => {
    routes[URL1] = () => htmlRes("denied", 403);
    await run(msg(job()), mkEnv({ BROWSER_RENDER_DAILY_PER_USER: "0" }));
    expect(quickAction).not.toHaveBeenCalled();
    expect(marked[0]).toMatchObject({ status: "failed", error: "http_403" });
    expect((await attempts())[0]).toMatchObject({ status: "failed", error_code: "http_403", error_detail: "render_budget", fallback_outcome: "budget", method: "fetch", http_status: 403 });
  });

  it("global budget is shared across users; per-user budget counts per user", async () => {
    routes[URL1] = () => htmlRes(SHORT);
    const env = mkEnv({ BROWSER_RENDER_DAILY_PER_USER: "1", BROWSER_RENDER_DAILY_GLOBAL: "2" });
    await run(msg(job({ userId: "a" })), env);
    await run(msg(job({ userId: "a", force: true })), env); // user a over
    await run(msg(job({ userId: "b", force: true })), env);
    await run(msg(job({ userId: "c", force: true })), env); // global over
    expect(quickAction).toHaveBeenCalledTimes(2);
    expect((await attempts()).map((r) => r.fallback_outcome)).toEqual(["ok", "budget", "ok", "budget"]);
    expect(marked[1]).toMatchObject({ status: "partial" }); // plain result kept
  });

  it("render disabled by env: fallback 'disabled'; transient 503 still retries", async () => {
    routes[URL1] = () => htmlRes(SHORT);
    await run(msg(job()), mkEnv({ BROWSER_RENDER_ENABLED: "false" }));
    expect(quickAction).not.toHaveBeenCalled();
    expect((await attempts())[0]).toMatchObject({ status: "partial", fallback_outcome: "disabled" });

    routes[URL1] = () => htmlRes("busy", 503);
    const m = msg(job({ force: true }));
    await run(m, mkEnv({ BROWSER_RENDER_ENABLED: "false" }));
    expect(m.retry).toHaveBeenCalled();
  });

  it("render failure keeps the plain result (partial) and records failed + detail", async () => {
    routes[URL1] = () => htmlRes(SHORT);
    quickAction.mockImplementation(async () => Response.json({ success: false, errors: [{ message: "boom" }] }, { status: 500 }));
    await run(msg(job()));
    expect(marked[0]).toMatchObject({ status: "partial" });
    expect((await attempts())[0]).toMatchObject({ status: "partial", method: "fetch", fallback_outcome: "failed", error_detail: "render_http_500" });
  });

  it("render of a 503 bot wall that succeeds avoids the retry", async () => {
    routes[URL1] = () => htmlRes("busy", 503);
    const m = msg(job());
    await run(m);
    expect(m.retry).not.toHaveBeenCalled();
    expect(marked[0]).toMatchObject({ status: "ok" });
  });
});

describe("site rules", () => {
  it("removeSelectors and contentSelector are applied", async () => {
    await putRule("example.com", { removeSelectors: [".ad", ".promo"] });
    await run(msg(job()));
    const t = await text(marked[0]!);
    expect(t).not.toContain("BUY NOW");
    expect((await attempts())[0]).toMatchObject({ rule_applied: 1 });

    clearSiteRuleCache();
    await putRule("example.com", { contentSelector: "#real" });
    await run(msg(job({ force: true })));
    expect(await text(marked[1]!)).toMatch(/^REAL/);
  });

  it("parent-domain rule applies to subdomains; www is ignored", async () => {
    await putRule("example.com", { disabled: true });
    expect((await loadSiteRule(base.CONFIG, "www.blog.example.com"))?.host).toBe("example.com");
    await run(msg(job({ url: "https://www.example.com/x" })));
    expect(fetched).toEqual([]);
    expect(marked[0]).toMatchObject({ status: "failed", error: "site_disabled" });
    expect((await attempts())[0]).toMatchObject({ status: "failed", error_code: "site_disabled", rule_applied: 1 });
  });

  it("render never / always", async () => {
    routes[URL1] = () => htmlRes(SHORT);
    await putRule("example.com", { render: "never" });
    await run(msg(job()));
    expect(quickAction).not.toHaveBeenCalled();
    expect((await attempts())[0]).toMatchObject({ fallback_outcome: "disabled", status: "partial" });

    clearSiteRuleCache();
    routes[URL1] = () => htmlRes(LONG);
    await putRule("example.com", { render: "always", waitForSelector: "article", userAgent: "browser" });
    await run(msg(job({ force: true })));
    expect(quickAction).toHaveBeenCalledTimes(1);
    expect(quickAction.mock.calls[0]![1]).toMatchObject({ waitForSelector: { selector: "article" }, userAgent: BROWSER_UA });
    expect(fetched.at(-1)).toMatchObject({ url: URL1, ua: BROWSER_UA });
    expect(marked[1]).toMatchObject({ status: "ok" });
    expect((await attempts())[1]).toMatchObject({ method: "render", fallback_outcome: "ok" });
  });

  it("minTextChars lowers the short-text threshold (no render, status ok)", async () => {
    routes[URL1] = () => htmlRes(SHORT);
    await putRule("example.com", { minTextChars: 100 });
    await run(msg(job()));
    expect(quickAction).not.toHaveBeenCalled();
    expect(marked[0]).toMatchObject({ status: "ok" });
  });

  it("invalid rules are ignored", async () => {
    await putRule("example.com", { render: "sometimes" });
    expect(await loadSiteRule(base.CONFIG, "example.com")).toBeNull();
    await putRule("other.com", "{not json");
    expect(await loadSiteRule(base.CONFIG, "other.com")).toBeNull();
    await run(msg(job()));
    expect(marked[0]).toMatchObject({ status: "ok" });
    expect((await attempts())[0]).toMatchObject({ rule_applied: 0 });
  });

  it("caches rules per isolate for 60 s (misses included)", async () => {
    const get = vi.spyOn(base.CONFIG, "get");
    const t = 1_000_000;
    expect(await loadSiteRule(base.CONFIG, "example.com", t)).toBeNull();
    await putRule("example.com", { render: "never" });
    expect(await loadSiteRule(base.CONFIG, "example.com", t + 1000)).toBeNull();
    expect(get).toHaveBeenCalledTimes(1);
    expect((await loadSiteRule(base.CONFIG, "example.com", t + RULE_CACHE_TTL_MS + 1))?.rule).toEqual({ render: "never" });
    expect(get).toHaveBeenCalledTimes(2);
  });
});

describe("parse_attempts", () => {
  it("records shared-cache hits as method cache", async () => {
    await run(msg(job()));
    await run(msg(job({ userId: "u2" })));
    const rows = await attempts();
    expect(rows.map((r) => r.method)).toEqual(["fetch", "cache"]);
    expect(rows[1]).toMatchObject({ status: "ok", user_hash: await hashId("u2", 16) });
    expect(metrics[1]!.blobs!.slice(5, 7)).toEqual(["hit", "cache"]);
  });

  it("records DLQ failures", async () => {
    await run(msg(job(), 5), mkEnv(), "sroka-parse-dlq");
    expect((await attempts())[0]).toMatchObject({ status: "failed", error_code: "parse_failed", error_detail: "dlq", attempt: 5 });
  });

  it("weekly purge drops rows older than 30 days and expired budgets", async () => {
    const now = Date.now();
    await base.DB.prepare(
      `INSERT INTO parse_attempts (id, created_at, user_hash, item_id, domain, status, method, fallback_outcome, attempt, parser_version)
       VALUES ('old', ?1, 'h', 'i', 'd', 'ok', 'fetch', 'none', 1, 1), ('new', ?2, 'h', 'i', 'd', 'ok', 'fetch', 'none', 1, 1)`,
    )
      .bind(now - 31 * 86400_000, now - 86400_000)
      .run();
    await base.DB.prepare("INSERT INTO render_budget (key, count, expires_at) VALUES ('g:1', 1, ?1), ('g:2', 1, ?2)").bind(now - 1, now + 1000).run();
    expect(await purgeParseAnalytics(base.DB, now)).toEqual({ attempts: 1, budget: 1 });
    expect((await attempts()).map((r) => r.id)).toEqual(["new"]);
  });
});

describe("paywall detection", () => {
  const LD = `<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>`;
  const PAYWALLED_SHORT = SHORT.replace("</head>", `${LD}</head>`);
  const PAYWALLED_LONG = LONG.replace("</head>", `${LD}</head>`);

  it("short teaser with paywall markup: partial/paywalled, no render budget spent", async () => {
    routes[URL1] = () => htmlRes(PAYWALLED_SHORT);
    await run(msg(job()));
    expect(quickAction).not.toHaveBeenCalled();
    expect(marked[0]).toMatchObject({ status: "partial", error: "paywalled" });
    const [row] = await attempts();
    expect(row).toMatchObject({ status: "partial", error_code: "paywalled", method: "fetch", fallback_outcome: "none" });
    const c = await base.DB.prepare("SELECT status, cacheable FROM content").first();
    expect(c).toEqual({ status: "partial", cacheable: 0 });
  });

  it("rendered page behind a bot wall that is a member-only preview: partial/paywalled via render", async () => {
    routes[URL1] = () => htmlRes("denied", 403);
    renderHtml = RENDERED.replace("<article>", "<div><span>Member-only story</span></div><article>");
    await run(msg(job()));
    expect(quickAction).toHaveBeenCalledTimes(1);
    expect(marked[0]).toMatchObject({ status: "partial", error: "paywalled" });
    expect((await attempts())[0]).toMatchObject({ method: "render", error_code: "paywalled" });
  });

  it("long page with paywall markup is still partial (full text kept)", async () => {
    routes[URL1] = () => htmlRes(PAYWALLED_LONG);
    await run(msg(job()));
    expect(marked[0]).toMatchObject({ status: "partial", error: "paywalled" });
    expect(await text(marked[0]!)).toContain("REAL");
  });

  it("captured HTML is never marked paywalled (the user's browser had access)", async () => {
    const rawKey = r2Keys.raw("u1", ITEM);
    const gz = await new Response(new Blob([PAYWALLED_LONG]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer();
    await base.CONTENT.put(rawKey, gz);
    await run(msg(job({ rawKey })));
    expect(marked[0]).toMatchObject({ status: "ok" });
    expect(marked[0]!.error).toBeUndefined();
  });
});
