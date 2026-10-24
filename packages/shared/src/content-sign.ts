/**
 * Signed content URLs (decisions D7).
 *
 *   {CONTENT_ORIGIN}/s/{exp}/{sig}/{scope}/{contentId}/{file}
 *   scope = "p" (public, R2 content/{contentId}/) | "u.{userId}" (private, R2 private/{userId}/{contentId}/)
 *   sig   = base64url(HMAC-SHA256(key, "{exp}/{scope}/{contentId}"))   (no padding)
 *   exp   = unix seconds
 *
 * The signature covers the directory, not the file, so relative `img/…` URLs inside article.html work.
 */
import { LIMITS } from "./limits.ts";

export type ContentScope = "p" | `u.${string}`;

const CONTENT_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const USER_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const FILE_SEGMENT_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/;

export function contentScope(contentPrivate: boolean, userId: string): ContentScope {
  return contentPrivate ? `u.${userId}` : "p";
}

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(s: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) return null;
  try {
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

const keyCache = new Map<string, Promise<CryptoKey>>();
function hmacKey(secret: string): Promise<CryptoKey> {
  let k = keyCache.get(secret);
  if (!k) {
    k = crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign", "verify"],
    );
    keyCache.set(secret, k);
  }
  return k;
}

function message(exp: number, scope: string, contentId: string): BufferSource {
  return new TextEncoder().encode(`${exp}/${scope}/${contentId}`);
}

/** Returns the base64url signature for (exp, scope, contentId). */
export async function signContentPath(
  secret: string,
  exp: number,
  scope: ContentScope,
  contentId: string,
): Promise<string> {
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), message(exp, scope, contentId));
  return b64url(new Uint8Array(sig));
}

export interface ContentDirInput {
  /** e.g. "https://c.sroka.app" or "http://127.0.0.1:8787" (no trailing slash needed). */
  origin: string;
  secret: string;
  scope: ContentScope;
  contentId: string;
  /** Unix seconds; default = now + ttlSec rounded UP to the next hour (better CDN cache reuse). */
  exp?: number;
  ttlSec?: number;
  /** Override "now" (ms) for tests. */
  now?: number;
}

/** Default expiry: now + ttl, rounded up to a whole hour so URLs are stable for a while. */
export function defaultExp(now = Date.now(), ttlSec: number = LIMITS.contentUrlTtlSec): number {
  const e = Math.floor(now / 1000) + ttlSec;
  return Math.ceil(e / 3600) * 3600;
}

/** Signed directory URL ending with "/" — use as `<base href>` for article.html. */
export async function buildContentBaseUrl(input: ContentDirInput): Promise<{ baseUrl: string; exp: number }> {
  const exp = input.exp ?? defaultExp(input.now, input.ttlSec);
  const sig = await signContentPath(input.secret, exp, input.scope, input.contentId);
  const origin = input.origin.replace(/\/+$/, "");
  return { baseUrl: `${origin}/s/${exp}/${sig}/${input.scope}/${input.contentId}/`, exp };
}

/** Signed URL of one file inside the content dir. */
export async function buildContentUrl(input: ContentDirInput & { file: string }): Promise<string> {
  const { baseUrl } = await buildContentBaseUrl(input);
  return baseUrl + input.file;
}

/** All URLs for GET /v1/items/:id/content. */
export async function buildContentUrls(
  input: ContentDirInput & { pdf?: boolean },
): Promise<{ articleUrl: string; baseUrl: string; packageUrl: string; documentUrl: string | null; expiresAt: number }> {
  const { baseUrl, exp } = await buildContentBaseUrl(input);
  return {
    articleUrl: `${baseUrl}article.html`,
    baseUrl,
    packageUrl: `${baseUrl}package.zip`,
    documentUrl: input.pdf ? `${baseUrl}document.pdf` : null,
    expiresAt: exp * 1000,
  };
}

export type VerifyResult =
  | { ok: true; scope: ContentScope; contentId: string; file: string; r2Key: string; isPrivate: boolean; exp: number }
  | { ok: false; reason: "malformed" | "expired" | "bad_signature" };

/**
 * Verifies a request pathname ("/s/{exp}/{sig}/{scope}/{contentId}/{file…}") and returns the R2 key.
 * Pass `new URL(req.url).pathname` unmodified — never decodeURIComponent it first (`%2F` would become a separator).
 * Signature check uses WebCrypto `verify` (constant-time).
 */
export async function verifyContentPath(
  secret: string,
  pathname: string,
  nowSec: number = Math.floor(Date.now() / 1000),
): Promise<VerifyResult> {
  const parts = pathname.split("/");
  // ["", "s", exp, sig, scope, contentId, ...file]
  if (parts.length < 7 || parts[0] !== "" || parts[1] !== "s") return { ok: false, reason: "malformed" };
  const [, , expStr, sig, scope, contentId, ...fileParts] = parts as [string, string, string, string, string, string, ...string[]];
  // Canonical forms only (no leading zeros, exactly 43 b64url chars) so one signature ↔ one URL.
  if (!/^[1-9]\d{0,11}$/.test(expStr)) return { ok: false, reason: "malformed" };
  if (!/^[A-Za-z0-9_-]{43}$/.test(sig)) return { ok: false, reason: "bad_signature" };
  if (!CONTENT_ID_RE.test(contentId)) return { ok: false, reason: "malformed" };
  let userId: string | null = null;
  if (scope !== "p") {
    if (!scope.startsWith("u.")) return { ok: false, reason: "malformed" };
    userId = scope.slice(2);
    if (!USER_ID_RE.test(userId)) return { ok: false, reason: "malformed" };
  }
  if (fileParts.length === 0 || fileParts.length > 4) return { ok: false, reason: "malformed" };
  for (const seg of fileParts) if (!FILE_SEGMENT_RE.test(seg) || seg.includes("..")) return { ok: false, reason: "malformed" };
  const sigBytes = b64urlDecode(sig);
  if (!sigBytes || sigBytes.length !== 32 || b64url(sigBytes) !== sig) return { ok: false, reason: "bad_signature" };
  const exp = Number(expStr);
  const valid = await crypto.subtle.verify(
    "HMAC",
    await hmacKey(secret),
    sigBytes as BufferSource,
    message(exp, scope, contentId),
  );
  if (!valid) return { ok: false, reason: "bad_signature" };
  if (exp < nowSec) return { ok: false, reason: "expired" };
  const file = fileParts.join("/");
  const r2Key = (userId ? `private/${userId}/${contentId}/` : `content/${contentId}/`) + file;
  return { ok: true, scope: scope as ContentScope, contentId, file, r2Key, isPrivate: userId !== null, exp };
}
