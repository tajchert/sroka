import { Readability } from "@mozilla/readability";
import Defuddle from "defuddle";
import { parseHTML } from "linkedom";
import { extractReddit } from "./reddit.ts";
import { absolutizeUrl } from "./sanitize.ts";

export interface Extracted {
  title: string | null;
  byline: string | null;
  siteName: string | null;
  lang: string | null;
  publishedTime: string | null;
  excerpt: string | null;
  /** Readability HTML (NOT sanitized yet). */
  contentHtml: string;
  text: string;
  /** Absolute og:image / twitter:image URL, if any. */
  leadImage: string | null;
}

const clean = (s: string | null | undefined): string | null => {
  const t = s?.replace(/\s+/g, " ").trim();
  return t ? t : null;
};

/** Extractor bylines sometimes carry link text or a profile URL: drop "By"-style prefixes, reject URLs and blurbs. */
export function cleanByline(s: string | null | undefined): string | null {
  const t = clean(s)?.replace(/^(?:view all posts by|posted by|written by|by)\s*:?\s+/i, "");
  if (!t || t.length > 100 || /^(?:https?:\/\/|www\.)/i.test(t)) return null;
  return t;
}

type Doc = ReturnType<typeof parseHTML>["document"];

function meta(doc: Doc, ...names: string[]): string | null {
  for (const n of names) {
    const el = doc.querySelector(`meta[property="${n}"], meta[name="${n}"]`);
    const v = clean(el?.getAttribute("content"));
    if (v) return v;
  }
  return null;
}

/** Collapse whitespace but keep paragraph breaks. */
export function normalizeText(t: string): string {
  return t
    .replace(/\r/g, "")
    .replace(/[ \t\f\v ]+/g, " ")
    .replace(/ ?\n ?/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Count words (Intl.Segmenter when available so CJK works, else whitespace split). */
export function countWords(text: string): number {
  if (!text) return 0;
  try {
    const seg = new Intl.Segmenter(undefined, { granularity: "word" });
    let n = 0;
    for (const s of seg.segment(text)) if (s.isWordLike) n++;
    return n;
  } catch {
    return text.split(/\s+/).filter(Boolean).length;
  }
}

/** Per-site extraction options (site rules, decisions D10). */
export interface ExtractOptions {
  /** CSS selectors whose elements are removed before extraction (invalid selectors are ignored). */
  removeSelectors?: readonly string[];
  /** CSS selector of the article element: used instead of Readability when it matches with enough text. */
  contentSelector?: string;
  /** Below this many text characters the result is `partial` (buildContent; default 500). */
  minTextChars?: number;
}

/** The linkedom element surface we use (works under both DOM lib and workers-types). */
interface El {
  textContent: string | null;
  innerHTML: string;
  remove(): void;
}

function safeQueryAll(doc: Doc, sel: string): El[] {
  try {
    return [...(doc.querySelectorAll(sel) as unknown as Iterable<El>)];
  } catch {
    return [];
  }
}

const NEVER_CONTENT = '[role="menu"], [role="menubar"]';

/** Parse `html` with the base URL set and the never-content + site-rule removals applied. */
function prepare(html: string, url: string, removeSelectors: readonly string[]): Doc {
  const { document } = parseHTML(html);
  try {
    Object.defineProperty(document, "baseURI", { value: url, configurable: true });
  } catch {
    /* ignore */
  }
  // Dropdown/menu widgets (site switchers, login menus) are never article content; in captured DOM the page's
  // scripts may have dropped the aria-hidden that would otherwise hide them.
  for (const sel of [NEVER_CONTENT, ...removeSelectors]) for (const el of safeQueryAll(document, sel)) el.remove();
  fixLazyImages(document);
  return document;
}

const IMG_EXT = "(?:jpe?g|png|webp|gif|avif)";
const SRCSET_VALUE = new RegExp(`\\.${IMG_EXT}(?:\\?\\S*)?\\s+\\d`, "i");
const SRC_VALUE = new RegExp(`^\\s*\\S+\\.${IMG_EXT}(?:\\?\\S*)?\\s*$`, "i");

/**
 * Lazy-loaded images keep the real URL in some other attribute (data-src, nitro-lazy-srcset, ...) and a
 * placeholder (or nothing) in src. Copy it into src/srcset so extractors that drop unknown attributes keep
 * the image (same idea as Readability's _fixLazyImages).
 */
interface ImgEl {
  tagName: string;
  getAttribute(name: string): string | null;
  setAttribute(name: string, value: string): void;
  getAttributeNames(): string[];
}

function fixLazyImages(doc: Doc): void {
  for (const img of safeQueryAll(doc, "img, picture source") as unknown as ImgEl[]) {
    const src = img.getAttribute("src")?.trim();
    if (src && !/^data:/i.test(src)) continue;
    for (const name of img.getAttributeNames()) {
      const value = img.getAttribute(name) ?? "";
      if (name === "src" || name === "srcset" || name === "alt") continue;
      if (SRCSET_VALUE.test(value)) {
        img.setAttribute("srcset", value);
        if (img.tagName === "IMG") img.setAttribute("src", value.trim().split(/\s+/)[0]!);
        break;
      }
      if (SRC_VALUE.test(value)) {
        img.setAttribute(img.tagName === "IMG" ? "src" : "srcset", value.trim());
        break;
      }
    }
  }
}

const htmlText = (html: string): string => normalizeText(parseHTML(`<!doctype html><html><body>${html}</body></html>`).document.body?.textContent ?? "");

/** Defuddle (generic main-content extractor; sync parse, so its site extractors never fetch). */
function runDefuddle(doc: Doc, url: string): { r: ReturnType<Defuddle["parse"]>; text: string } | null {
  try {
    const r = new Defuddle(doc as never, { url, useAsync: false }).parse();
    return r.content ? { r, text: htmlText(r.content) } : null;
  } catch {
    return null;
  }
}

function runReadability(doc: Doc): { article: NonNullable<ReturnType<Readability["parse"]>>; text: string } | null {
  try {
    const article = new Readability(doc as never, { charThreshold: 100 }).parse();
    return article?.content ? { article, text: normalizeText(article.textContent ?? "") } : null;
  } catch {
    return null;
  }
}

/**
 * Extract the main article from `html`: site extractors, else a site-rule contentSelector, else Defuddle,
 * with Readability as the fallback when Defuddle finds less than `minTextChars` (the longer text wins).
 * Returns null if no article content could be extracted.
 */
export function extractArticle(html: string, url: string, opts: ExtractOptions = {}): Extracted | null {
  // Site-specific extractors first (they return null when the page doesn't look as expected).
  const site = extractReddit(html, url);
  if (site) return site;
  const removeSelectors = opts.removeSelectors ?? [];
  const document = prepare(html, url, removeSelectors);
  // Metadata must be read before the extractors mutate the document.
  const ogSite = meta(document, "og:site_name", "application-name");
  const ogImage = absolutizeUrl(meta(document, "og:image", "og:image:url", "twitter:image", "twitter:image:src") ?? undefined, url);
  const docLang = clean(document.documentElement?.getAttribute("lang")) ?? meta(document, "og:locale");
  const ogTitle = meta(document, "og:title");
  const ogDesc = meta(document, "og:description", "description");
  const published = meta(document, "article:published_time", "og:article:published_time", "date", "pubdate");
  const metaAuthor = meta(document, "author", "article:author");

  let host: string | null = null;
  try {
    host = new URL(url).hostname.replace(/^www\./, "");
  } catch {
    /* ignore */
  }

  if (opts.contentSelector) {
    const el = safeQueryAll(document, opts.contentSelector)[0];
    const text = el ? normalizeText(el.textContent ?? "") : "";
    if (el && text.length >= 40) {
      const docTitle = clean(document.querySelector("title")?.textContent);
      const h1 = clean(document.querySelector("h1")?.textContent);
      return {
        title: ogTitle ?? docTitle ?? h1,
        byline: metaAuthor,
        siteName: ogSite ?? host,
        lang: docLang,
        publishedTime: published,
        excerpt: ogDesc ?? clean(text.slice(0, 300)),
        contentHtml: el.innerHTML,
        text,
        leadImage: ogImage,
      };
    }
  }

  const d = runDefuddle(document, url);
  const minChars = opts.minTextChars ?? 500;
  // Readability needs its own copy: Defuddle has already rewritten this one.
  const rd = !d || d.text.length < minChars ? runReadability(prepare(html, url, removeSelectors)) : null;

  if (d && d.text.length >= 40 && (!rd || d.text.length >= rd.text.length)) {
    const { r, text } = d;
    return {
      title: clean(r.title) ?? ogTitle,
      byline: cleanByline(r.author) ?? cleanByline(metaAuthor),
      siteName: clean(r.site) ?? ogSite ?? host,
      lang: clean(r.language) ?? docLang,
      publishedTime: clean(r.published) ?? published,
      excerpt: clean(r.description) ?? ogDesc ?? clean(text.slice(0, 300)),
      contentHtml: r.content,
      text,
      leadImage: ogImage ?? absolutizeUrl(clean(r.image) ?? undefined, url),
    };
  }
  if (!rd || rd.text.length < 40) return null;
  const { article, text } = rd;
  return {
    title: clean(article.title) ?? ogTitle,
    byline: cleanByline(article.byline),
    siteName: clean(article.siteName) ?? ogSite ?? host,
    lang: clean(article.lang) ?? docLang,
    publishedTime: clean(article.publishedTime) ?? published,
    excerpt: clean(article.excerpt) ?? ogDesc ?? clean(text.slice(0, 300)),
    contentHtml: article.content ?? "",
    text,
    leadImage: ogImage,
  };
}
