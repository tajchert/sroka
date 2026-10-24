/** Pure helpers for PDF jobs (no unpdf import): title cleanup, text normalization, excerpt, word count. */

export const TEXT_FILE = "text.txt";
export const PDF_MAX_PAGES = 300;
export const PDF_MAX_TEXT_BYTES = 2 * 1024 * 1024;
const EXCERPT_CHARS = 300;
const TITLE_MAX = 200;

const GENERIC_TITLES = new Set([
  "untitled",
  "untitled document",
  "untitled presentation",
  "powerpoint presentation",
  "document",
  "slide 1",
  "title",
  "no title",
  "none",
  "null",
  "undefined",
  "(anonymous)",
  "unknown",
]);
/** "Microsoft Word - ", "Microsoft PowerPoint - ", "Microsoft Excel - " prefix produced by old Office PDF printers. */
const OFFICE_PREFIX = /^microsoft\s+(?:office\s+)?(?:word|powerpoint|excel|publisher|visio)\s*-\s*/i;
const FILE_EXT = /\.(?:docx?|dotx?|pptx?|xlsx?|odt|rtf|txt|pdf|indd|tex|pages|key|html?|md)$/i;

/** Metadata Title -> display title, or null (caller keeps the provisional file-name title). */
export function cleanPdfTitle(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  // eslint-disable-next-line no-control-regex
  let t = raw.replace(/[\u0000-\u001f\u007f﻿]/g, " ").replace(/\s+/g, " ").trim();
  if (!t) return null;
  t = t.replace(OFFICE_PREFIX, "").trim();
  // A file path (unix, windows, drive letter, file:// URL), also after prefix removal.
  if (/[\\/]/.test(t) || /^[a-z]:/i.test(t) || /^[a-z][a-z0-9+.-]*:\/\//i.test(t)) return null;
  t = t.replace(FILE_EXT, "").trim();
  if (t.length < 2) return null;
  if (GENERIC_TITLES.has(t.toLowerCase())) return null;
  if (/^(?:document|untitled|slide|page)\s*\d*$/i.test(t)) return null;
  return t.length > TITLE_MAX ? `${t.slice(0, TITLE_MAX - 1).trimEnd()}…` : t;
}

/** Plain short string metadata (Author) or null. */
export function cleanPdfString(raw: unknown, max = 200): string | null {
  if (typeof raw !== "string") return null;
  // eslint-disable-next-line no-control-regex
  const t = raw.replace(/[\u0000-\u001f\u007f﻿]/g, " ").replace(/\s+/g, " ").trim();
  if (!t || GENERIC_TITLES.has(t.toLowerCase())) return null;
  return t.slice(0, max);
}

/** BCP-47-ish language tag from the PDF catalog `Lang`/`Language`, else null. */
export function cleanPdfLang(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const t = raw.trim().replace(/_/g, "-");
  return /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/.test(t) ? t : null;
}

/** Collapse runs of spaces/tabs, trim lines, and at most one blank line in a row. */
export function normalizePdfText(text: string): string {
  return text
    .replace(/\r\n?/g, "\n")
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, " ")
    .replace(/[ \t ]+/g, " ")
    .replace(/ ?\n ?/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function wordCountOf(text: string): number {
  const m = text.match(/\S+/g);
  return m ? m.length : 0;
}

/** First ~300 chars of whitespace-flattened text, cut at a word boundary; null when empty. */
export function pdfExcerpt(text: string): string | null {
  const flat = text.replace(/\s+/g, " ").trim();
  if (!flat) return null;
  if (flat.length <= EXCERPT_CHARS) return flat;
  const cut = flat.slice(0, EXCERPT_CHARS);
  const sp = cut.lastIndexOf(" ");
  return `${(sp > EXCERPT_CHARS * 0.6 ? cut.slice(0, sp) : cut).trimEnd()}…`;
}

/** Cap UTF-8 size of `text` at `maxBytes` (never splits a code point). */
export function capUtf8(text: string, maxBytes = PDF_MAX_TEXT_BYTES): { bytes: Uint8Array; truncated: boolean } {
  const enc = new TextEncoder().encode(text);
  if (enc.length <= maxBytes) return { bytes: enc, truncated: false };
  let end = maxBytes;
  while (end > 0 && (enc[end]! & 0xc0) === 0x80) end--; // back off to a code point start
  return { bytes: enc.subarray(0, end), truncated: true };
}
