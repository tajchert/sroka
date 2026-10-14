import { assertFetchable, BlockedUrlError } from "./ssrf.ts";

export type FetchKind = "html" | "image" | "pdf" | "other";

export class FetchError extends Error {
  /** Machine code: blocked_url, http_<status>, timeout, too_large, too_many_redirects, not_html, network, bad_redirect */
  constructor(
    public code: string,
    /** true = worth retrying later (timeouts, network, 5xx, 429) */
    public transient = false,
  ) {
    super(code);
  }
}

export interface SafeFetchOptions {
  fetch?: typeof fetch;
  /** Hostnames we must never fetch (our own origins). */
  ownHosts?: readonly string[];
  timeoutMs?: number;
  maxBytes?: number;
  maxRedirects?: number;
  /** Accepted content kinds; others throw FetchError("not_html"). Default ["html"]. */
  allow?: readonly FetchKind[];
  userAgent?: string;
  accept?: string;
}

export interface SafeFetchResult {
  /** Final URL after redirects (use as base for relative links). */
  url: string;
  status: number;
  contentType: string;
  kind: FetchKind;
  bytes: Uint8Array;
  redirects: number;
}

export const DEFAULT_UA = "Mozilla/5.0 (compatible; SrokaBot/1.0; +https://sroka.app/bot)";

export function kindOf(contentType: string): FetchKind {
  const t = contentType.split(";")[0]!.trim().toLowerCase();
  if (t === "text/html" || t === "application/xhtml+xml") return "html";
  if (t.startsWith("image/")) return "image";
  if (t === "application/pdf") return "pdf";
  return "other";
}

async function readCapped(res: Response, maxBytes: number, signal: AbortSignal): Promise<Uint8Array> {
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    await res.body?.cancel().catch(() => {});
    throw new FetchError("too_large");
  }
  if (!res.body) return new Uint8Array(0);
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  const aborted = new Promise<never>((_, rej) => {
    if (signal.aborted) rej(new FetchError("timeout", true));
    signal.addEventListener("abort", () => rej(new FetchError("timeout", true)), { once: true });
  });
  aborted.catch(() => {});
  try {
    for (;;) {
      const { done, value } = await Promise.race([reader.read(), aborted]);
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        throw new FetchError("too_large");
      }
      chunks.push(value);
    }
  } catch (e) {
    if (e instanceof FetchError) {
      if (e.code === "timeout") await reader.cancel().catch(() => {});
      throw e;
    }
    throw new FetchError(signal.aborted ? "timeout" : "network", true);
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.byteLength;
  }
  return out;
}

function blocked(e: unknown): never {
  if (e instanceof BlockedUrlError) throw new FetchError("blocked_url");
  throw e;
}

/**
 * SSRF-safe GET: http(s) only, private/loopback/own hosts blocked on every hop, manual redirects,
 * overall timeout (incl. body), streamed size cap, content-type dispatch.
 */
export async function safeFetch(rawUrl: string, opts: SafeFetchOptions = {}): Promise<SafeFetchResult> {
  const {
    fetch: f = (...a: Parameters<typeof fetch>) => fetch(...a),
    ownHosts = [],
    timeoutMs = 15_000,
    maxBytes = 5 * 1024 * 1024,
    maxRedirects = 5,
    allow = ["html"],
    userAgent = DEFAULT_UA,
    accept = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
  } = opts;

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    let current: URL;
    try {
      current = assertFetchable(rawUrl, ownHosts);
    } catch (e) {
      blocked(e);
    }
    for (let hop = 0; ; hop++) {
      let res: Response;
      try {
        res = await f(current.href, {
          method: "GET",
          redirect: "manual",
          signal: ctrl.signal,
          headers: { "user-agent": userAgent, accept, "accept-language": "en,*;q=0.5" },
        });
      } catch {
        throw new FetchError(ctrl.signal.aborted ? "timeout" : "network", true);
      }
      if (res.status >= 300 && res.status < 400 && res.status !== 304) {
        const loc = res.headers.get("location");
        await res.body?.cancel().catch(() => {});
        if (!loc) throw new FetchError("bad_redirect");
        if (hop >= maxRedirects) throw new FetchError("too_many_redirects");
        try {
          current = assertFetchable(new URL(loc, current), ownHosts);
        } catch (e) {
          if (e instanceof BlockedUrlError) throw new FetchError("blocked_url");
          throw new FetchError("bad_redirect");
        }
        continue;
      }
      if (res.status < 200 || res.status >= 300) {
        await res.body?.cancel().catch(() => {});
        const transient = res.status >= 500 || res.status === 429 || res.status === 408;
        throw new FetchError(`http_${res.status}`, transient);
      }
      const contentType = res.headers.get("content-type") ?? "";
      // Missing content-type on a 2xx: treat as html and let extraction decide.
      const kind = contentType === "" ? "html" : kindOf(contentType);
      if (!allow.includes(kind)) {
        await res.body?.cancel().catch(() => {});
        throw new FetchError("not_html");
      }
      const bytes = await readCapped(res, maxBytes, ctrl.signal);
      return { url: current.href, status: res.status, contentType, kind, bytes, redirects: hop };
    }
  } finally {
    clearTimeout(timer);
  }
}

/** Decode HTML bytes using the header charset, then a <meta charset> sniff, default UTF-8. */
export function decodeHtml(bytes: Uint8Array, contentType = ""): string {
  let label = /charset\s*=\s*["']?([\w.:-]+)/i.exec(contentType)?.[1];
  if (!label) {
    const head = new TextDecoder("latin1").decode(bytes.subarray(0, 4096));
    label = /<meta[^>]+charset\s*=\s*["']?\s*([\w.:-]+)/i.exec(head)?.[1] ?? /<meta[^>]+content=["'][^"']*charset=([\w.:-]+)/i.exec(head)?.[1];
  }
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) label = "utf-8";
  try {
    return new TextDecoder(label ?? "utf-8").decode(bytes);
  } catch {
    return new TextDecoder("utf-8").decode(bytes);
  }
}
