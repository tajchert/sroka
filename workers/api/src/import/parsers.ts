import { type ImportFormat, LIMITS, normalizeTagName, tryNormalizeUrl } from "@sroka/shared";
import { unzipSync } from "fflate";
import { parseCsv } from "./csv.ts";
import { scanBookmarks } from "./html.ts";

export interface ImportRow {
  url: string;
  title?: string;
  /** Epoch ms. */
  savedAt?: number;
  tags: string[];
  status: "unread" | "archived";
  isFavorite: boolean;
}

export interface ParsedImport {
  rows: ImportRow[];
  /** Entries that had no usable http(s) URL. */
  invalid: number;
}

export class ImportParseError extends Error {
  constructor(readonly code: string, message?: string) {
    super(message ?? code);
  }
}

const decoder = new TextDecoder("utf-8");

const MAX_ZIP_ENTRY = 40 * 1024 * 1024;
const MAX_ZIP_TOTAL = 50 * 1024 * 1024;
const MAX_ZIP_ENTRIES = 20;

/** unix seconds (or ms, if clearly ms) to epoch ms; undefined for empty/invalid/non-positive. */
export function parseTimestamp(v: string | undefined): number | undefined {
  if (!v) return undefined;
  const n = Number(v.trim());
  if (!Number.isFinite(n) || n <= 0) return undefined;
  return Math.floor(n >= 1e11 ? n : n * 1000);
}

function cleanTags(raw: Iterable<string>): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const t of raw) {
    const name = normalizeTagName(t);
    if (!name || name.length > LIMITS.maxTagLength) continue;
    const key = name.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(name);
    if (out.length >= LIMITS.maxTagsPerItem) break;
  }
  return out;
}

/** Pocket writes `a|b`; some exports use commas. A cell containing `|` splits on `|`, otherwise on `,`. */
export function splitTags(cell: string | undefined): string[] {
  if (!cell) return [];
  return cleanTags(cell.split(cell.includes("|") ? "|" : ","));
}

function validUrl(u: string | undefined): string | null {
  const t = (u ?? "").trim();
  if (!t || t.length > LIMITS.maxUrlLength) return null;
  return tryNormalizeUrl(t) === null ? null : t;
}

/** Undo the export's formula-injection guard: `'=...` / `'+...` etc. */
function unguard(v: string | undefined): string | undefined {
  return v !== undefined && /^'[=+\-@\t\r]/.test(v) ? v.slice(1) : v;
}

function title(t: string | undefined): string | undefined {
  const v = (t ?? "").trim();
  return v ? v.slice(0, LIMITS.maxTitleLength) : undefined;
}

function csvRecords(text: string): { header: Map<string, number>; body: string[][] } {
  const all = parseCsv(text);
  if (all.length === 0) return { header: new Map(), body: [] };
  const header = new Map<string, number>();
  all[0]!.forEach((h, i) => {
    const k = h.trim().toLowerCase();
    if (!header.has(k)) header.set(k, i);
  });
  return { header, body: all.slice(1) };
}

function parsePocketCsvText(text: string): ParsedImport {
  const { header, body } = csvRecords(text);
  if (!header.has("url")) throw new ImportParseError("missing_url_column", "CSV has no url column");
  const col = (r: string[], name: string) => (header.has(name) ? r[header.get(name)!] : undefined);
  const rows: ImportRow[] = [];
  let invalid = 0;
  for (const r of body) {
    const url = validUrl(col(r, "url"));
    if (!url) {
      invalid++;
      continue;
    }
    const status = (col(r, "status") ?? "").trim().toLowerCase();
    rows.push({
      url,
      title: title(unguard(col(r, "title"))),
      savedAt: parseTimestamp(col(r, "time_added")),
      tags: splitTags(unguard(col(r, "tags"))),
      status: status === "archive" || status === "archived" || status === "read" ? "archived" : "unread",
      isFavorite: ["1", "true", "yes"].includes((col(r, "favorite") ?? "").trim().toLowerCase()),
    });
  }
  return { rows, invalid };
}

function isZip(b: Uint8Array): boolean {
  return b.length > 4 && b[0] === 0x50 && b[1] === 0x4b && b[2] === 0x03 && b[3] === 0x04;
}

export function parsePocketCsv(bytes: Uint8Array): ParsedImport {
  if (!isZip(bytes)) return parsePocketCsvText(decoder.decode(bytes));
  let files: Record<string, Uint8Array>;
  try {
    let total = 0;
    let count = 0;
    files = unzipSync(bytes, {
      filter: (f) => {
        if (!/\.csv$/i.test(f.name) || f.name.includes("__MACOSX")) return false;
        total += f.originalSize;
        if (f.originalSize > MAX_ZIP_ENTRY || total > MAX_ZIP_TOTAL || ++count > MAX_ZIP_ENTRIES) {
          throw new ImportParseError("zip_too_large", "The zip is too large when uncompressed");
        }
        return true;
      },
    });
  } catch (e) {
    if (e instanceof ImportParseError) throw e;
    throw new ImportParseError("bad_zip", "Could not read the zip archive");
  }
  const names = Object.keys(files).sort();
  if (names.length === 0) throw new ImportParseError("no_csv_in_zip", "The zip contains no CSV files");
  const out: ParsedImport = { rows: [], invalid: 0 };
  for (const n of names) {
    const p = parsePocketCsvText(decoder.decode(files[n]!));
    out.rows.push(...p.rows);
    out.invalid += p.invalid;
  }
  return out;
}

function parseHtml(bytes: Uint8Array, mode: "pocket" | "netscape"): ParsedImport {
  const html = decoder.decode(bytes);
  const rows: ImportRow[] = [];
  let invalid = 0;
  let archived = false;
  for (const ev of scanBookmarks(html)) {
    if (ev.kind === "heading") {
      if (mode === "pocket" && ev.level <= 2) archived = /archive|^read$/i.test(ev.text);
      continue;
    }
    const url = validUrl(ev.attrs.href);
    if (!url) {
      invalid++;
      continue;
    }
    const tagsAttr = ev.attrs.tags;
    rows.push({
      url,
      title: title(ev.text),
      savedAt: parseTimestamp(ev.attrs.time_added ?? ev.attrs.add_date),
      tags: tagsAttr ? cleanTags(tagsAttr.split(",")) : [],
      status: mode === "pocket" && archived ? "archived" : "unread",
      isFavorite: false,
    });
  }
  return { rows, invalid };
}

export const parsePocketHtml = (b: Uint8Array) => parseHtml(b, "pocket");
export const parseNetscapeHtml = (b: Uint8Array) => parseHtml(b, "netscape");

export function parseInstapaperCsv(bytes: Uint8Array): ParsedImport {
  const { header, body } = csvRecords(decoder.decode(bytes));
  if (!header.has("url")) throw new ImportParseError("missing_url_column", "CSV has no URL column");
  const col = (r: string[], name: string) => (header.has(name) ? r[header.get(name)!] : undefined);
  const rows: ImportRow[] = [];
  let invalid = 0;
  for (const r of body) {
    const url = validUrl(col(r, "url"));
    if (!url) {
      invalid++;
      continue;
    }
    const folder = (col(r, "folder") ?? "").trim();
    const f = folder.toLowerCase();
    const tags: string[] = [];
    const rawTags = (col(r, "tags") ?? "").trim();
    if (rawTags) {
      try {
        const j: unknown = JSON.parse(rawTags);
        if (Array.isArray(j)) tags.push(...j.filter((x): x is string => typeof x === "string"));
        else tags.push(...rawTags.split(","));
      } catch {
        tags.push(...rawTags.split(","));
      }
    }
    if (folder && !["unread", "archive", "starred"].includes(f)) tags.push(folder);
    rows.push({
      url,
      title: title(col(r, "title")),
      savedAt: parseTimestamp(col(r, "timestamp")),
      tags: cleanTags(tags),
      status: f === "archive" ? "archived" : "unread",
      isFavorite: f === "starred",
    });
  }
  return { rows, invalid };
}

/** Parses an upload; rows come back newest first (rows without a date last, file order otherwise). */
export function parseImport(format: ImportFormat, bytes: Uint8Array): ParsedImport {
  let p: ParsedImport;
  switch (format) {
    case "pocket_csv":
      p = parsePocketCsv(bytes);
      break;
    case "pocket_html":
      p = parsePocketHtml(bytes);
      break;
    case "instapaper_csv":
      p = parseInstapaperCsv(bytes);
      break;
    case "netscape_html":
      p = parseNetscapeHtml(bytes);
      break;
  }
  if (p.rows.length + p.invalid > LIMITS.maxImportItems) {
    throw new ImportParseError("too_many_rows", `More than ${LIMITS.maxImportItems} rows`);
  }
  p.rows = p.rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => (b.r.savedAt ?? 0) - (a.r.savedAt ?? 0) || a.i - b.i)
    .map((x) => x.r);
  return p;
}
