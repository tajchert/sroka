import { PARSER_VERSION, readingMinutes } from "@sroka/shared";
import { countWords, extractArticle } from "./extract.ts";
import { processImages, type ImageTransform } from "./images.ts";
import { buildArticleHtml, buildPackage } from "./package.ts";
import type { SafeFetchOptions } from "./safe-fetch.ts";
import { rewriteImages, sanitizeArticle } from "./sanitize.ts";

export interface OutputFile {
  /** path relative to the content dir */
  path: string;
  bytes: Uint8Array;
  contentType: string;
}

export interface ContentMeta {
  title: string | null;
  excerpt: string | null;
  siteName: string | null;
  author: string | null;
  lang: string | null;
  publishedTime: string | null;
  wordCount: number;
  readingMinutes: number;
}

export interface BuildContentResult {
  status: "ok" | "partial";
  meta: ContentMeta;
  /** article.html, text.txt, img/*, thumb.webp (if any), package.zip */
  files: OutputFile[];
  /** "thumb.webp" when a thumbnail was produced */
  leadImageKey?: string;
  /** total bytes of package.zip */
  packageBytes: number;
}

export interface BuildContentOptions {
  html: string;
  /** base URL for relative links (final URL after redirects, or the saved URL for captured HTML) */
  url: string;
  contentId: string;
  transform: ImageTransform;
  fetchOptions: SafeFetchOptions;
  parserVersion?: number;
}

const enc = new TextEncoder();
const PARTIAL_BELOW_CHARS = 500;

/** HTML -> Readability -> sanitize -> images -> article.html/text.txt/package.zip. Returns null if nothing extractable. */
export async function buildContent(o: BuildContentOptions): Promise<BuildContentResult | null> {
  const ex = extractArticle(o.html, o.url);
  if (!ex) return null;
  const san = sanitizeArticle(ex.contentHtml, o.url);
  const leadCandidates = [ex.leadImage, san.images[0]].filter((x): x is string => !!x);
  const imgs = await processImages({ urls: san.images, leadCandidates, transform: o.transform, fetchOptions: o.fetchOptions });
  const bodyHtml = rewriteImages(san.html, (u) => imgs.byUrl.get(u)?.path ?? null);

  const text = ex.text;
  const wordCount = countWords(text);
  const minutes = readingMinutes(wordCount);
  const articleHtml = buildArticleHtml(bodyHtml, { title: ex.title, byline: ex.byline, siteName: ex.siteName, lang: ex.lang, url: o.url });
  const parserVersion = o.parserVersion ?? PARSER_VERSION;
  const pkg = await buildPackage({
    contentId: o.contentId,
    parserVersion,
    title: ex.title,
    byline: ex.byline,
    siteName: ex.siteName,
    lang: ex.lang,
    wordCount,
    readingMinutes: minutes,
    articleHtml,
    images: imgs.files.map((f) => ({ path: f.path, bytes: f.bytes })),
  });

  const files: OutputFile[] = [
    { path: "article.html", bytes: enc.encode(articleHtml), contentType: "text/html; charset=utf-8" },
    { path: "text.txt", bytes: enc.encode(text), contentType: "text/plain; charset=utf-8" },
    ...imgs.files.map((f) => ({ path: f.path, bytes: f.bytes, contentType: f.contentType })),
    { path: "package.zip", bytes: pkg.zip, contentType: "application/zip" },
  ];
  if (imgs.thumb) files.push({ path: "thumb.webp", bytes: imgs.thumb, contentType: "image/webp" });

  return {
    status: text.length < PARTIAL_BELOW_CHARS ? "partial" : "ok",
    meta: {
      title: ex.title,
      excerpt: ex.excerpt,
      siteName: ex.siteName,
      author: ex.byline,
      lang: ex.lang,
      publishedTime: ex.publishedTime,
      wordCount,
      readingMinutes: minutes,
    },
    files,
    leadImageKey: imgs.thumb ? "thumb.webp" : undefined,
    packageBytes: pkg.zip.byteLength,
  };
}
