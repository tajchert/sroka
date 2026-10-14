import {
  buildContent,
  decodeHtml,
  FetchError,
  type ImageTransform,
  type SafeFetchOptions,
  safeFetch,
} from "@sroka/extractor";
import { normalizeUrl, PARSER_VERSION, r2Keys, urlHash, uuidv7, type ParseJob, type ParseResult } from "@sroka/shared";
import type { ParserEnv } from "./env.ts";

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
}

/** Shared-cache lookup (public content only). Degrades to a miss on any D1/R2 error. */
async function cacheLookup(env: ParserEnv, hash: string, now: number): Promise<{ id: string; meta: CachedMeta } | null> {
  try {
    const row = await env.DB.prepare(
      // Only full ('ok') parses are shared: a 'partial' row is typically a bot wall / consent / paywall page.
      "SELECT id FROM content WHERE url_hash = ?1 AND parser_version = ?2 AND status = 'ok' AND parsed_at > ?3 ORDER BY parsed_at DESC LIMIT 1",
    )
      .bind(hash, PARSER_VERSION, now - CACHE_TTL_MS)
      .first<{ id: string }>();
    if (!row) return null;
    const obj = await env.CONTENT.get(`${r2Keys.contentDir(row.id)}meta.json`);
    if (!obj) return null;
    return { id: row.id, meta: (await obj.json()) as CachedMeta };
  } catch (e) {
    console.warn("cache lookup failed", e);
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
    ...(m.status === "partial" ? { error: "partial_content" } : {}),
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
): Promise<ParseResult | null> {
  const isPrivate = !!job.rawKey;
  let canonical: string;
  try {
    canonical = normalizeUrl(job.url);
  } catch {
    return failedResult(job, "invalid_url");
  }
  const hash = await urlHash(canonical);
  const now = deps.now();
  const sharedCache = !isPrivate && sharesCacheKey(job.url, canonical);

  if (sharedCache && !job.force) {
    const hit = await cacheLookup(env, hash, now);
    if (hit) return resultFrom(job, hit.id, false, hit.meta);
  }

  const fetchOptions: SafeFetchOptions = { fetch: deps.fetch, ownHosts: ownHosts(env) };

  // 1. obtain HTML
  let html: string;
  let baseUrl = job.url;
  try {
    if (job.rawKey) {
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
      const res = await safeFetch(job.url, fetchOptions);
      html = decodeHtml(res.bytes, res.contentType);
      baseUrl = res.url;
    }
  } catch (e) {
    if (e instanceof FetchError) {
      if (e.transient) throw e;
      return failedResult(job, e.code);
    }
    throw e;
  }

  // 2. extract + sanitize + images + package
  const contentId = deps.newId();
  let built;
  try {
    built = await buildContent({
      html,
      url: baseUrl,
      contentId,
      transform: deps.transform ?? imagesTransform(env),
      fetchOptions,
    });
  } catch (e) {
    // deterministic parser crash (linkedom/Readability/fflate): retrying won't help
    console.warn(`buildContent threw for ${job.itemId}: ${e instanceof Error ? e.message : e}`);
    return failedResult(job, "extract_failed");
  }
  if (!built) {
    // TODO(BROWSER_RENDER_ENABLED): when env.BROWSER_RENDER_ENABLED === "true", enqueue a Browser Run render and re-extract here.
    return failedResult(job, "extract_failed");
  }

  if (stillWanted && !(await stillWanted())) return null;

  // 3. write R2 (fresh contentId => write-once keys); meta.json last = cache-validity marker
  const dir = r2Keys.contentDir(contentId, isPrivate ? job.userId : null);
  const cached: CachedMeta = {
    status: built.status,
    title: built.meta.title,
    excerpt: built.meta.excerpt,
    siteName: built.meta.siteName,
    author: built.meta.author,
    lang: built.meta.lang,
    wordCount: built.meta.wordCount,
    readingMinutes: built.meta.readingMinutes,
    ...(built.leadImageKey ? { leadImageKey: built.leadImageKey } : {}),
  };
  try {
    // One at a time: concurrent puts would keep every request body buffered at once.
    for (const f of built.files) await env.CONTENT.put(dir + f.path, f.bytes, { httpMetadata: { contentType: f.contentType } });
    await env.CONTENT.put(`${dir}meta.json`, JSON.stringify(cached), { httpMetadata: { contentType: "application/json" } });
  } catch (e) {
    throw new TransientError(`r2 put: ${e}`);
  }

  // 4. shared cache row (public, canonical fetch, full parse only). Failure here is non-fatal.
  if (sharedCache && built.status === "ok") {
    try {
      await env.DB.prepare(
        "INSERT INTO content (id, url_hash, canonical_url, parser_version, status, title, word_count, lang, bytes, ref_count, parsed_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, ?10)",
      )
        .bind(contentId, hash, canonical, PARSER_VERSION, built.status, built.meta.title, built.meta.wordCount, built.meta.lang, built.packageBytes, now)
        .run();
    } catch (e) {
      console.warn("content row insert failed", e);
    }
  }

  return resultFrom(job, contentId, isPrivate, cached);
}

/**
 * api.md section 9: the parser ref-counts shared content. Called after markParsed returned ok (first accept
 * for that parse gen) for a public ok/partial result (fresh parse or cache hit). Errors are swallowed.
 * NOTE: nothing decrements ref_count yet and there is no shared-content GC (see docs/ledger.md).
 */
export async function incrementRefCount(env: ParserEnv, result: ParseResult): Promise<void> {
  if (result.status === "failed" || result.contentPrivate || !result.contentId) return;
  try {
    await env.DB.prepare("UPDATE content SET ref_count = ref_count + 1 WHERE id = ?1").bind(result.contentId).run();
  } catch (e) {
    console.warn("ref_count increment failed", e);
  }
}
