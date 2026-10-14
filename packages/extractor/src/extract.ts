import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
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

/** Run Readability over `html`. Returns null if no article content could be extracted. */
export function extractArticle(html: string, url: string): Extracted | null {
  const { document } = parseHTML(html);
  try {
    Object.defineProperty(document, "baseURI", { value: url, configurable: true });
  } catch {
    /* ignore */
  }
  // Metadata must be read before Readability mutates the document.
  const ogSite = meta(document, "og:site_name", "application-name");
  const ogImage = absolutizeUrl(meta(document, "og:image", "og:image:url", "twitter:image", "twitter:image:src") ?? undefined, url);
  const docLang = clean(document.documentElement?.getAttribute("lang")) ?? meta(document, "og:locale");
  const ogTitle = meta(document, "og:title");
  const ogDesc = meta(document, "og:description", "description");
  const published = meta(document, "article:published_time", "og:article:published_time", "date", "pubdate");

  let article: ReturnType<Readability["parse"]>;
  try {
    article = new Readability(document as never, { charThreshold: 100 }).parse();
  } catch {
    return null;
  }
  if (!article || !article.content) return null;
  const text = normalizeText(article.textContent ?? "");
  if (text.length < 40) return null;

  let host: string | null = null;
  try {
    host = new URL(url).hostname.replace(/^www\./, "");
  } catch {
    /* ignore */
  }
  return {
    title: clean(article.title) ?? ogTitle,
    byline: clean(article.byline),
    siteName: clean(article.siteName) ?? ogSite ?? host,
    lang: clean(article.lang) ?? docLang,
    publishedTime: clean(article.publishedTime) ?? published,
    excerpt: clean(article.excerpt) ?? ogDesc ?? clean(text.slice(0, 300)),
    contentHtml: article.content,
    text,
    leadImage: ogImage,
  };
}
