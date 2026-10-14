import { strToU8, zipSync, type Zippable } from "fflate";
import type { PackageManifest } from "@sroka/shared";
import { sha256Hex } from "./images.ts";

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export interface ArticleDocMeta {
  title: string | null;
  byline: string | null;
  siteName: string | null;
  lang: string | null;
  /** original URL (shown as plain text/link; not an external resource reference) */
  url: string;
}

/** Minimal self-contained HTML document: no scripts, no external refs. Reader injects theme/CSP/base. */
export function buildArticleHtml(contentHtml: string, m: ArticleDocMeta): string {
  const lang = m.lang && /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(m.lang) ? m.lang : "en";
  const title = m.title ?? m.siteName ?? m.url;
  const byline = [m.byline, m.siteName].filter(Boolean).join(" · ");
  return (
    `<!doctype html>\n<html lang="${esc(lang)}">\n<head>\n<meta charset="utf-8">\n` +
    `<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>${esc(title)}</title>\n</head>\n<body>\n<article>\n` +
    `<h1>${esc(title)}</h1>\n` +
    (byline ? `<p class="byline">${esc(byline)}</p>\n` : "") +
    `${contentHtml}\n</article>\n</body>\n</html>\n`
  );
}

export interface PackageInput {
  contentId: string;
  parserVersion: number;
  title: string | null;
  byline: string | null;
  siteName: string | null;
  lang: string | null;
  wordCount: number;
  readingMinutes: number;
  articleHtml: string;
  images: Array<{ path: string; bytes: Uint8Array }>;
}

export async function buildPackage(p: PackageInput): Promise<{ manifest: PackageManifest; zip: Uint8Array }> {
  const articleBytes = strToU8(p.articleHtml);
  const files: PackageManifest["files"] = [{ path: "article.html", sha256: await sha256Hex(articleBytes), bytes: articleBytes.byteLength }];
  for (const img of p.images) files.push({ path: img.path, sha256: await sha256Hex(img.bytes), bytes: img.bytes.byteLength });
  const manifest: PackageManifest = {
    format: 1,
    contentId: p.contentId,
    parserVersion: p.parserVersion,
    title: p.title,
    byline: p.byline,
    siteName: p.siteName,
    lang: p.lang,
    wordCount: p.wordCount,
    readingMinutes: p.readingMinutes,
    files,
  };
  const z: Zippable = {
    "manifest.json": [strToU8(JSON.stringify(manifest, null, 2)), { level: 6 }],
    "article.html": [articleBytes, { level: 6 }],
  };
  // Images are already compressed: store, don't deflate.
  for (const img of p.images) z[img.path] = [img.bytes, { level: 0 }];
  return { manifest, zip: zipSync(z) };
}
