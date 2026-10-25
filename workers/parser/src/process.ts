import {
  BOT_WALL_STATUSES,
  BROWSER_UA,
  buildContent,
  decodeHtml,
  detectBotWall,
  detectPaywall,
  extractArticle,
  extractHackerNews,
  extractTweet,
  FetchError,
  PARTIAL_BELOW_CHARS,
  type BotWall,
  type Extracted,
  type ExtractOptions,
  type ImageTransform,
  type SafeFetchOptions,
  safeFetch,
  hnItemId,
  tweetRef,
} from "@sroka/extractor";
import { displayDomain, hashId, log, normalizeUrl, PARSER_VERSION, r2Keys, urlHash, uuidv7, type ParseJob, type ParseResult } from "@sroka/shared";
import type { ParserEnv } from "./env.ts";
import { processPdfJob } from "./pdf.ts";
import { renderEnabled, renderPage, takeRenderBudget } from "./render.ts";
import { loadSiteRule, stripParams } from "./site-rules.ts";

export const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_RAW_BYTES = 12 * 1024 * 1024;

/** Thrown for failures worth retrying (R2/D1/network hiccups). */
export class TransientError extends Error {}

export interface Deps {
  fetch: typeof fetch;
  now: () => number;
  newId: () => string;
  /** Override image transform (tests). Default uses env.IMAGES. */
  transform?: ImageTransform;
}

export const defaultDeps: Deps = {
  // late-bound so tests can stub globalThis.fetch
  fetch: (...a) => globalThis.fetch(...a),
  now: () => Date.now(),
  newId: () => uuidv7(),
};

/** `api`: a site JSON API (X / Twitter posts) instead of the page. */
export type ParseMethod = "fetch" | "render" | "capture" | "cache" | "api" | "pdf";
export type FallbackOutcome = "none" | "ok" | "partial" | "failed" | "budget" | "disabled";

/** Out-param of processJob for the per-job log / metric / parse_attempts row (all optional). */
export interface JobStats {
  cacheHit?: boolean;
  /** Package bytes (0 on cache hit / failure). */
  bytes?: number;
  images?: number;
  /** Where the HTML that was used came from. */
  method?: ParseMethod;
  /** Browser Run fallback: none = not needed, disabled = needed but off (env or rule), budget = over budget. */
  fallbackOutcome?: FallbackOutcome;
  /** A KV site rule matched the host. */
  ruleApplied?: boolean;
  renderMs?: number;
  textChars?: number;
  /** Origin HTTP status of the plain fetch (or of the rendered page when its HTML was used). */
  httpStatus?: number;
  /** Extra failure detail (render error, render_budget). */
  errorDetail?: string;
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
}

/** extractArticle that never throws (linkedom/Readability crash = nothing extractable). */
function safeExtract(html: string, url: string, opts: ExtractOptions, itemId: string): Extracted | null {
  try {
    return extractArticle(html, url, opts);
  } catch (e) {
    log.warnException("extractArticle threw", e, { event: "build_content_failed", itemId });
    return null;
  }
}

export function failedResult(job: ParseJob, error: string): ParseResult {
  return {
    status: "failed",
    parseGen: job.parseGen,
    contentPrivate: false,
    title: null,
    excerpt: null,
    siteName: null,
    author: null,
    lang: null,
    wordCount: null,
    readingMinutes: null,
    error,
    parserVersion: PARSER_VERSION,
  };
}

export function ownHosts(env: ParserEnv): string[] {
  const out: string[] = [];
  for (const o of [env.APP_ORIGIN, env.API_ORIGIN, env.CONTENT_ORIGIN]) {
    try {
      out.push(new URL(o).hostname);
    } catch {
      /* ignore */
    }
  }
  return out;
}

export function imagesTransform(env: ParserEnv): ImageTransform {
  return async (bytes, _type, { width }) => {
    // Stream the bytes as-is (no Blob copy of a possibly 10 MB download).
    const input = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(bytes);
        c.close();
      },
    });
    const out = await env.IMAGES.input(input)
      .transform({ width, fit: "scale-down" })
      .output({ format: "image/webp", quality: 80 });
    const buf = await new Response(out.image()).arrayBuffer();
    return { bytes: new Uint8Array(buf), contentType: out.contentType() };
  };
}

async function gunzip(body: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const stream = body.pipeThrough(new DecompressionStream("gzip"));
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_RAW_BYTES) {
      await reader.cancel();
      throw new FetchError("too_large");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.byteLength;
  }
  return out;
}

interface CachedMeta {
  status: "ok" | "partial";
  title: string | null;
  excerpt: string | null;
  siteName: string | null;
  author: string | null;
  lang: string | null;
  wordCount: number | null;
  readingMinutes: number | null;
  leadImageKey?: string;
  /** Reason for a `partial` status (default `partial_content`), e.g. `paywalled`. */
  error?: string;
}

/**
 * Shared-cache lookup (public content only). Degrades to a miss on any D1/R2 error. The lookup and the
 * `last_used_at` touch are one statement, so the GC (which marks a row only while `last_used_at` is older than
 * its grace period, and never a touched one) can't collect content that a cache hit is about to attach.
 */
async function cacheLookup(env: ParserEnv, hash: string, now: number): Promise<{ id: string; meta: CachedMeta } | null> {
  try {
    const row = await env.DB.prepare(
      // Only full ('ok') canonical parses are shared: a 'partial' row is typically a bot wall / consent / paywall page.
      `UPDATE content SET last_used_at = MAX(last_used_at, ?4) WHERE id = (
         SELECT id FROM content WHERE url_hash = ?1 AND parser_version = ?2 AND status = 'ok' AND cacheable = 1
           AND gc_at IS NULL AND parsed_at > ?3 ORDER BY parsed_at DESC LIMIT 1) RETURNING id`,
    )
      .bind(hash, PARSER_VERSION, now - CACHE_TTL_MS, now)
      .first<{ id: string }>();
    if (!row) return null;
    const obj = await env.CONTENT.get(`${r2Keys.contentDir(row.id)}meta.json`);
    if (!obj) return null;
    return { id: row.id, meta: (await obj.json()) as CachedMeta };
  } catch (e) {
    log.warnException("cache lookup failed", e, { event: "cache_lookup_failed" });
    return null;
  }
}

function resultFrom(job: ParseJob, contentId: string, isPrivate: boolean, m: CachedMeta): ParseResult {
  return {
    status: m.status,
    parseGen: job.parseGen,
    contentId,
    contentPrivate: isPrivate,
    title: m.title,
    excerpt: m.excerpt,
    siteName: m.siteName,
    author: m.author,
    lang: m.lang,
    wordCount: m.wordCount,
    readingMinutes: m.readingMinutes,
    ...(m.leadImageKey ? { leadImageKey: m.leadImageKey } : {}),
    ...(m.status === "partial" ? { error: m.error ?? "partial_content" } : {}),
    parserVersion: PARSER_VERSION,
  };
}

/**
 * True when fetching `url` yields exactly what the shared cache key (its canonical form) stands for: same
 * query parameters in the same order (only the fragment / credentials may differ). Fetches of any other
 * variant (tracking params that may be echoed into the page, reordered order-sensitive queries) must neither
 * read nor fill the cache shared by all users.
 */
export function sharesCacheKey(url: string, canonical: string): boolean {
  try {
    const u = new URL(url.trim());
    u.hash = "";
    u.username = "";
    u.password = "";
    if (u.hostname.endsWith(".")) u.hostname = u.hostname.replace(/\.+$/, "");
    if (u.search === "?") u.search = "";
    return u.href === canonical;
  } catch {
    return false;
  }
}

/**
 * Parse one job. Returns a ParseResult (ok/partial/failed for permanent outcomes), or null when
 * `stillWanted` reports (right before the R2 writes) that the job was superseded meanwhile.
 * Throws TransientError / transient FetchError when the job should be retried.
 */
export async function processJob(
  env: ParserEnv,
  job: ParseJob,
  deps: Deps = defaultDeps,
  stillWanted?: () => Promise<boolean>,
  stats: JobStats = {},
): Promise<ParseResult | null> {
  if (job.pdf) {
    return processPdfJob(env, job, stillWanted, stats);
  }
  const isPrivate = !!job.rawKey;
  stats.method = isPrivate ? "capture" : "fetch";
  stats.fallbackOutcome = "none";
  let canonical: string;
  try {
    canonical = normalizeUrl(job.url);
  } catch {
    return failedResult(job, "invalid_url");
  }
  const hash = await urlHash(canonical);
  const now = deps.now();
  const sharedCache = !isPrivate && sharesCacheKey(job.url, canonical);

  // Site rule (KV CONFIG, 60 s isolate cache). Applies to captures too, except the render settings.
  const site = await loadSiteRule(env.CONFIG, hostOf(job.url), now);
  const rule = site?.rule;
  stats.ruleApplied = !!rule;
  if (rule?.disabled) return failedResult(job, "site_disabled");
  const extractOptions: ExtractOptions = {
    ...(rule?.removeSelectors ? { removeSelectors: rule.removeSelectors } : {}),
    ...(rule?.contentSelector ? { contentSelector: rule.contentSelector } : {}),
    ...(rule?.minTextChars !== undefined ? { minTextChars: rule.minTextChars } : {}),
  };
  const minChars = rule?.minTextChars ?? PARTIAL_BELOW_CHARS;

  if (sharedCache && !job.force) {
    const hit = await cacheLookup(env, hash, now);
    if (hit) {
      stats.cacheHit = true;
      stats.method = "cache";
      return resultFrom(job, hit.id, false, hit.meta);
    }
  }

  const fetchOptions: SafeFetchOptions = { fetch: deps.fetch, ownHosts: ownHosts(env) };
  const pageUrl = isPrivate ? job.url : stripParams(job.url, rule?.stripParams);

  // 0. X / Twitter posts and Hacker News items: the JSON APIs beat both the page and a capture of it (captures too:
  // what the API returns is public). A post is complete however short it is, so it is never `partial` and never
  // rendered. Hacker News: the story with its comment tree (D13).
  const apiArticle = tweetRef(job.url)
    ? await extractTweet(job.url, fetchOptions)
    : hnItemId(job.url)
      ? await extractHackerNews(job.url, fetchOptions)
      : null;
  if (apiArticle) {
    stats.method = "api";
    extractOptions.minTextChars = 1;
  }

  // 1. obtain HTML (captured raw HTML, or a plain fetch). Bot-wall statuses are kept for the render fallback.
  let html: string | null = null;
  let baseUrl = job.url;
  let fetchErr: FetchError | null = null;
  try {
    if (apiArticle) {
      // nothing to fetch
    } else if (job.rawKey) {
      let obj: R2ObjectBody | null;
      try {
        obj = await env.CONTENT.get(job.rawKey);
      } catch (e) {
        throw new TransientError(`r2 get: ${e}`);
      }
      if (!obj) return failedResult(job, "raw_missing");
      let raw: Uint8Array;
      try {
        raw = await gunzip(obj.body);
      } catch (e) {
        if (e instanceof FetchError) throw e;
        return failedResult(job, "raw_corrupt");
      }
      // Captured HTML is stored as UTF-8 (JSON string); ignore the page's original <meta charset>.
      html = decodeHtml(raw, "text/html; charset=utf-8");
    } else {
      const res = await safeFetch(pageUrl, { ...fetchOptions, ...(rule?.userAgent === "browser" ? { userAgent: BROWSER_UA } : {}) });
      stats.httpStatus = res.status;
      html = decodeHtml(res.bytes, res.contentType);
      baseUrl = res.url;
    }
  } catch (e) {
    if (!(e instanceof FetchError)) throw e;
    const status = /^http_(\d{3})$/.exec(e.code)?.[1];
    if (status) stats.httpStatus = Number(status);
    if (isPrivate || !status || !BOT_WALL_STATUSES.includes(Number(status))) {
      if (e.transient) throw e;
      return failedResult(job, e.code);
    }
    fetchErr = e;
  }

  // 2a. extract (cheap) and decide whether the Browser Run fallback is needed (never for captured HTML)
  let wall: BotWall | null = null;
  let chosen: Extracted | null = null;
  // A logged-out page of a paywalled article only has the teaser (never checked for captures: the user had access).
  let paywalled = false;
  if (apiArticle) chosen = apiArticle;
  else if (html !== null) {
    wall = isPrivate ? null : detectBotWall(html);
    if (wall !== "challenge") chosen = safeExtract(html, baseUrl, extractOptions, job.itemId);
    paywalled = !isPrivate && !!chosen && detectPaywall(html);
  }
  // 2a'. A capture with little text (cookie/consent wall, collapsed or not-yet-loaded content): try a plain server
  // fetch and keep whichever text is longer. The result stays private either way (no render, no shared cache).
  if (isPrivate && !apiArticle && (!chosen || chosen.text.length < minChars)) {
    try {
      const res = await safeFetch(stripParams(job.url, rule?.stripParams), {
        ...fetchOptions,
        ...(rule?.userAgent === "browser" ? { userAgent: BROWSER_UA } : {}),
      });
      const fhtml = decodeHtml(res.bytes, res.contentType);
      const fex = detectBotWall(fhtml) === "challenge" ? null : safeExtract(fhtml, res.url, extractOptions, job.itemId);
      if (!fex) {
        stats.fallbackOutcome = "failed";
        stats.errorDetail = "fetch_extract_failed";
      } else {
        stats.fallbackOutcome = fex.text.length >= minChars ? "ok" : "partial";
        if (!chosen || fex.text.length > chosen.text.length) {
          chosen = fex;
          baseUrl = res.url;
          paywalled = detectPaywall(fhtml);
          stats.method = "fetch";
          stats.httpStatus = res.status;
        }
      }
    } catch (e) {
      if (!(e instanceof FetchError)) throw e;
      stats.fallbackOutcome = "failed";
      stats.errorDetail = `fetch_${e.code}`;
    }
  }
  let trigger: string | null = null;
  if (!isPrivate && !apiArticle) {
    if (fetchErr) trigger = fetchErr.code;
    else if (wall === "challenge") trigger = "challenge";
    else if (!chosen) trigger = wall ?? "extract_failed";
    // A short paywall teaser stays short when rendered: don't spend render budget on it.
    else if (chosen.text.length < minChars && !paywalled) trigger = wall ?? "short";
    else if (rule?.render === "always") trigger = "rule_always";
  }
  if (trigger) {
    if (rule?.render === "never" || !renderEnabled(env)) {
      stats.fallbackOutcome = "disabled";
    } else if (!(await takeRenderBudget(env, await hashId(job.userId, 16), now))) {
      stats.fallbackOutcome = "budget";
      stats.errorDetail = "render_budget";
    } else {
      const r = await renderPage(env, pageUrl, {
        ...(rule?.waitForSelector ? { waitForSelector: rule.waitForSelector } : {}),
        browserUa: rule?.userAgent === "browser",
        ownHosts: fetchOptions.ownHosts ?? [],
      });
      stats.renderMs = r.ms;
      log.info("browser render", { event: "render", domain: displayDomain(job.url), trigger, ok: r.ok, ms: r.ms, itemId: job.itemId });
      if (!r.ok) {
        stats.fallbackOutcome = "failed";
        stats.errorDetail = r.error;
      } else {
        const rWall = detectBotWall(r.html);
        const rex = rWall === "challenge" ? null : safeExtract(r.html, r.finalUrl, extractOptions, job.itemId);
        if (!rex) {
          stats.fallbackOutcome = "failed";
          stats.errorDetail = rWall === "challenge" ? "render_bot_wall" : "render_extract_failed";
        } else {
          const better = !chosen || rex.text.length >= minChars || rex.text.length > chosen.text.length;
          stats.fallbackOutcome = rex.text.length >= minChars ? "ok" : "partial";
          if (better) {
            chosen = rex;
            paywalled = detectPaywall(r.html);
            baseUrl = r.finalUrl;
            stats.method = "render";
            if (r.httpStatus !== null) stats.httpStatus = r.httpStatus;
          }
        }
      }
    }
  }
  if (!chosen) {
    if (fetchErr) {
      if (fetchErr.transient) throw fetchErr;
      return failedResult(job, fetchErr.code);
    }
    return failedResult(job, wall === "challenge" ? "bot_wall" : "extract_failed");
  }

  // 2b. sanitize + images + package
  const contentId = deps.newId();
  let built;
  try {
    built = await buildContent({
      html: "",
      extracted: chosen,
      extractOptions,
      url: baseUrl,
      contentId,
      transform: deps.transform ?? imagesTransform(env),
      fetchOptions,
    });
  } catch (e) {
    // deterministic parser crash (linkedom/Readability/fflate): retrying won't help
    log.warnException("buildContent threw", e, { event: "build_content_failed", itemId: job.itemId });
    return failedResult(job, "extract_failed");
  }
  if (!built) return failedResult(job, "extract_failed");

  stats.cacheHit = false;
  stats.bytes = built.packageBytes;
  stats.images = built.files.filter((f) => f.path.startsWith("img/")).length;
  stats.textChars = built.textChars;
  if (stillWanted && !(await stillWanted())) return null;

  // 3. write R2 (fresh contentId => write-once keys); meta.json last = cache-validity marker
  const dir = r2Keys.contentDir(contentId, isPrivate ? job.userId : null);
  const cached: CachedMeta = {
    status: paywalled ? "partial" : built.status,
    ...(paywalled ? { error: "paywalled" } : {}),
    title: built.meta.title,
    excerpt: built.meta.excerpt,
    siteName: built.meta.siteName,
    author: built.meta.author,
    lang: built.meta.lang,
    wordCount: built.meta.wordCount,
    readingMinutes: built.meta.readingMinutes,
    ...(built.leadImageKey ? { leadImageKey: built.leadImageKey } : {}),
  };
  // Every public dir gets a D1 `content` row BEFORE its R2 writes, so the GC can always find (and eventually
  // collect) it — even when the R2 writes or markParsed fail, or the result is rejected as stale. Only canonical
  // full parses are `cacheable` (shared cache, api.md §9); the cache also requires meta.json (written last).
  if (!isPrivate) {
    try {
      await env.DB.prepare(
        `INSERT INTO content (id, url_hash, canonical_url, parser_version, status, title, word_count, lang, bytes, ref_count,
           parsed_at, cacheable, last_used_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, ?10, ?11, ?10)`,
      )
        .bind(
          contentId,
          hash,
          canonical,
          PARSER_VERSION,
          cached.status,
          built.meta.title,
          built.meta.wordCount,
          built.meta.lang,
          built.packageBytes,
          now,
          sharedCache && cached.status === "ok" ? 1 : 0,
        )
        .run();
    } catch (e) {
      throw new TransientError(`content row insert: ${e}`);
    }
  }
  try {
    // One at a time: concurrent puts would keep every request body buffered at once.
    for (const f of built.files) await env.CONTENT.put(dir + f.path, f.bytes, { httpMetadata: { contentType: f.contentType } });
    await env.CONTENT.put(`${dir}meta.json`, JSON.stringify(cached), { httpMetadata: { contentType: "application/json" } });
  } catch (e) {
    throw new TransientError(`r2 put: ${e}`);
  }

  return resultFrom(job, contentId, isPrivate, cached);
}
