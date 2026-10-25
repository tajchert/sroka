import sanitizeHtml from "sanitize-html";

/** Keeps a mailto: link (allowlisted scheme) — no control chars / whitespace, bounded length. */
function mailtoHref(raw: string): string | undefined {
  if (raw.length > 2048 || /[\s\u0000-\u001f\u007f<>"]/.test(raw)) return undefined;
  return "mailto:" + raw.slice("mailto:".length);
}

/** Resolve `value` against `base`; null if not an http(s) URL. */

export function absolutizeUrl(value: string | undefined, base: string): string | null {
  if (!value) return null;
  const v = value.trim();
  if (!v) return null;
  try {
    const u = new URL(v, base);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    u.hash = u.hash; // keep fragment for links
    return u.href;
  } catch {
    return null;
  }
}

const TRACKER_HOSTS = [
  "doubleclick.net",
  "google-analytics.com",
  "googletagmanager.com",
  "googleadservices.com",
  "googlesyndication.com",
  "scorecardresearch.com",
  "quantserve.com",
  "adsrvr.org",
  "facebook.net",
  "pixel.wp.com",
  "stats.wp.com",
  "pixel.quantserve.com",
  "bat.bing.com",
  "analytics.twitter.com",
  "t.co",
  "ads.linkedin.com",
  "px.ads.linkedin.com",
  "demdex.net",
  "omtrdc.net",
  "chartbeat.net",
  "hotjar.com",
  "mixpanel.com",
  "segment.io",
  "criteo.com",
  "taboola.com",
  "outbrain.com",
];

export function isTrackerUrl(u: string): boolean {
  try {
    const x = new URL(u);
    const h = x.hostname.toLowerCase();
    if (TRACKER_HOSTS.some((t) => h === t || h.endsWith("." + t))) return true;
    if (h.endsWith("facebook.com") && x.pathname.startsWith("/tr")) return true;
    return /^\/(pixel|beacon|track|collect)(\.gif|\.png)?$/i.test(x.pathname);
  } catch {
    return true;
  }
}

/** Pick the best URL from a srcset (largest width descriptor, else the last candidate). */
export function bestFromSrcset(srcset: string): string | undefined {
  let best: { url: string; w: number } | undefined;
  for (const part of srcset.split(/,\s+|,(?=\S+\s+\d)/)) {
    const [url, desc] = part.trim().split(/\s+/);
    if (!url) continue;
    const w = desc?.endsWith("w") ? parseInt(desc, 10) : desc?.endsWith("x") ? parseFloat(desc) * 1000 : 0;
    if (!best || w >= best.w) best = { url, w };
  }
  return best?.url;
}

function pickImgSrc(a: Record<string, string>): string | undefined {
  const real = (s: string | undefined) => (s && !/^data:/i.test(s.trim()) ? s : undefined);
  return (
    real(a["src"]) ??
    real(a["data-src"]) ??
    real(a["data-lazy-src"]) ??
    real(a["data-original"]) ??
    (a["srcset"] || a["data-srcset"] ? bestFromSrcset((a["srcset"] || a["data-srcset"])!) : undefined)
  );
}

export interface SanitizeResult {
  html: string;
  /** Absolute http(s) image URLs in document order (deduplicated). */
  images: string[];
}

/** Classes of the X / Twitter post cards (twitter.ts), styled by the readers. Everything else loses its class. */
export const POST_CLASSES = {
  div: ["sr-thread", "sr-post", "sr-post-focus", "sr-post-body", "sr-comments", "sr-replies", "sr-reply"],
  blockquote: ["sr-post", "sr-post-quote", "sr-note"],
  p: ["sr-post-head", "sr-post-stats", "sr-thread-foot"],
  span: ["sr-post-who", "sr-post-date"],
  img: ["sr-avatar"],
};

const ALLOWED_TAGS = [
  "h1", "h2", "h3", "h4", "h5", "h6", "p", "a", "img", "ul", "ol", "li", "blockquote", "pre", "code", "em", "strong", "b", "i", "u",
  "s", "del", "ins", "mark", "small", "br", "hr", "figure", "figcaption", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
  "sup", "sub", "dl", "dt", "dd", "span", "div", "section", "article", "details", "summary", "abbr", "cite", "q", "kbd", "time",
];

/**
 * Sanitize Readability output: strict allowlist, absolute URLs, no scripts/styles/forms/iframes/event handlers,
 * no tracking pixels; iframes become link cards; images collected (srcset dropped, best candidate kept as src).
 */
export function sanitizeArticle(contentHtml: string, baseUrl: string): SanitizeResult {
  const images: string[] = [];
  const html = sanitizeHtml(contentHtml, {
    allowedTags: ALLOWED_TAGS,
    allowedAttributes: {
      a: ["href", "title", "rel", "target", "class"],
      img: ["src", "alt", "title", "width", "height"],
      th: ["colspan", "rowspan"],
      td: ["colspan", "rowspan"],
      time: ["datetime"],
      abbr: ["title"],
      ol: ["start"],
    },
    allowedClasses: { a: ["embed-card"], ...POST_CLASSES },
    allowedSchemes: ["http", "https", "mailto"],
    allowedSchemesAppliedToAttributes: ["href", "src"],
    allowProtocolRelative: false,
    disallowedTagsMode: "discard",
    nonTextTags: ["script", "style", "textarea", "option", "noscript", "svg", "template", "math", "object", "embed", "select"],
    transformTags: {
      a: (tag, attribs) => {
        const raw = attribs["href"]?.trim();
        const href = raw?.startsWith("#") ? raw : raw && /^mailto:/i.test(raw) ? mailtoHref(raw) : absolutizeUrl(raw, baseUrl);
        const out: Record<string, string> = {};
        if (href) {
          out["href"] = href;
          if (!href.startsWith("#")) {
            out["rel"] = "noopener noreferrer nofollow";
            out["target"] = "_blank";
          }
        }
        if (attribs["title"]) out["title"] = attribs["title"];
        return { tagName: tag, attribs: out };
      },
      img: (tag, attribs) => {
        const abs = absolutizeUrl(pickImgSrc(attribs), baseUrl);
        const out: Record<string, string> = {};
        if (abs && !isTrackerUrl(abs)) out["src"] = abs;
        for (const k of ["alt", "title", "width", "height", "class"]) if (attribs[k] !== undefined) out[k] = attribs[k]!;
        return { tagName: tag, attribs: out };
      },
      iframe: (_tag, attribs) => {
        const src = absolutizeUrl(attribs["src"] || attribs["data-src"], baseUrl);
        if (!src) return { tagName: "span", attribs: {} as Record<string, string> };
        let host = src;
        try {
          host = new URL(src).hostname;
        } catch {
          /* keep */
        }
        return { tagName: "a", attribs: { href: src, class: "embed-card", rel: "noopener noreferrer nofollow", target: "_blank" }, text: `Embedded content (${host})` };
      },
    },
    exclusiveFilter: (frame) => {
      if (frame.tag === "img") {
        const src = frame.attribs["src"];
        if (!src) return true;
        const w = frame.attribs["width"] !== undefined ? parseInt(frame.attribs["width"], 10) : NaN;
        const h = frame.attribs["height"] !== undefined ? parseInt(frame.attribs["height"], 10) : NaN;
        if ((w <= 1 && h <= 1) || w === 0 || h === 0) return true;
        return false;
      }
      return false;
    },
  });
  // Collect images from sanitized output (canonical double-quoted attributes).
  const seen = new Set<string>();
  for (const m of html.matchAll(/<img\b[^>]*?\bsrc="([^"]*)"/g)) {
    const u = decodeAttr(m[1]!);
    if (!seen.has(u)) {
      seen.add(u);
      images.push(u);
    }
  }
  return { html, images };
}

function decodeAttr(s: string): string {
  return s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">");
}

function encodeAttr(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/**
 * Rewrite <img src> of sanitized HTML. `map(url)` returns the new relative path, or null to drop the image.
 * Operates on sanitizeArticle output only.
 */
export function rewriteImages(html: string, map: (url: string) => string | null): string {
  return html.replace(/<img\b[^>]*?>/g, (tag) => {
    const m = /\bsrc="([^"]*)"/.exec(tag);
    if (!m) return "";
    const next = map(decodeAttr(m[1]!));
    if (next === null) return "";
    return tag.replace(m[0], `src="${encodeAttr(next)}"`);
  });
}
