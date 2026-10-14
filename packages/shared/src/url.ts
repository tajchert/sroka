/**
 * URL normalization for dedupe (canonical_url / url_hash).
 *
 * Rules (documented in docs/api.md "URL normalization"):
 *  1. Only http/https; anything else throws InvalidUrlError.
 *  2. Scheme and host lowercased (WHATWG URL does this; IDN → punycode). A trailing dot on the host is removed.
 *  3. Default ports (:80 for http, :443 for https) dropped.
 *  4. Userinfo (user:pass@) dropped.
 *  5. Fragment dropped.
 *  6. Tracking params dropped: any `utm_*` plus TRACKING_PARAMS (case-insensitive name match).
 *  7. Remaining query params sorted by name (stable — repeated names keep their relative order);
 *     an empty query ("?") is removed.
 *  8. Path kept as-is (percent-encoding normalized by WHATWG URL). Trailing slashes are NOT stripped:
 *     `/a` and `/a/` may be different resources on some servers. Empty path becomes "/".
 *  9. `www.` is NOT removed (www and apex can be different sites). Scheme is NOT upgraded (http stays http).
 */

export const TRACKING_PARAMS: ReadonlySet<string> = new Set([
  "fbclid",
  "gclid",
  "dclid",
  "gbraid",
  "wbraid",
  "msclkid",
  "mc_eid",
  "mc_cid",
  "igshid",
  "ref_src",
  "_hsenc",
  "_hsmktg",
  "yclid",
]);

export class InvalidUrlError extends Error {
  constructor(message = "invalid_url") {
    super(message);
    this.name = "InvalidUrlError";
  }
}

export function isTrackingParam(name: string): boolean {
  const n = name.toLowerCase();
  return n.startsWith("utm_") || TRACKING_PARAMS.has(n);
}

/** True if `s` parses as an absolute http(s) URL. */
export function isHttpUrl(s: string): boolean {
  try {
    const u = new URL(s);
    return (u.protocol === "http:" || u.protocol === "https:") && u.hostname.length > 0;
  } catch {
    return false;
  }
}

/** Returns the canonical form of `input`. Throws InvalidUrlError for non-http(s)/unparseable input. */
export function normalizeUrl(input: string): string {
  let u: URL;
  try {
    u = new URL(input.trim());
  } catch {
    throw new InvalidUrlError();
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new InvalidUrlError();
  if (!u.hostname) throw new InvalidUrlError();

  u.username = "";
  u.password = "";
  u.hash = "";
  if (u.hostname.endsWith(".")) u.hostname = u.hostname.replace(/\.+$/, "");
  // WHATWG URL already strips default ports and lowercases scheme/host.

  const kept: [string, string][] = [];
  for (const [k, v] of u.searchParams) if (!isTrackingParam(k)) kept.push([k, v]);
  kept.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)); // Array#sort is stable
  if (kept.length === 0) {
    u.search = "";
  } else {
    const sp = new URLSearchParams();
    for (const [k, v] of kept) sp.append(k, v);
    u.search = sp.toString();
  }
  if (u.pathname === "") u.pathname = "/";
  return u.href;
}

/** Safe variant: canonical URL or null. */
export function tryNormalizeUrl(input: string): string | null {
  try {
    return normalizeUrl(input);
  } catch {
    return null;
  }
}

/** sha256(canonicalUrl) as lowercase hex (WebCrypto). */
export async function urlHash(canonicalUrl: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalUrl));
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Hostname without a leading "www." — for display and the `domain` list filter. */
export function displayDomain(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

const URL_IN_TEXT = /https?:\/\/[^\s<>"'`]+/i;
const TRAILING_PUNCT = /[.,;:!?'"»”’…]+$/;

/**
 * First http(s) URL in free text (e.g. Android share "Title https://…"). Strips trailing punctuation
 * and unbalanced closing brackets. Returns null if none.
 */
export function extractFirstUrl(text: string): string | null {
  const m = URL_IN_TEXT.exec(text);
  if (!m) return null;
  let s = m[0];
  for (;;) {
    const before = s;
    s = s.replace(TRAILING_PUNCT, "");
    for (const [open, close] of [["(", ")"], ["[", "]"], ["{", "}"]] as const) {
      if (s.endsWith(close)) {
        const opens = s.split(open).length - 1;
        const closes = s.split(close).length - 1;
        if (closes > opens) s = s.slice(0, -1);
      }
    }
    if (s === before) break;
  }
  return isHttpUrl(s) ? s : null;
}
