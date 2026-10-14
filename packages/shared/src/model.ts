import { z } from "zod";
import { LIMITS } from "./limits.ts";

/** Epoch milliseconds. */
export const EpochMs = z.number().int().nonnegative();

export const ParseStatus = z.enum(["pending", "ok", "partial", "failed"]);
export type ParseStatus = z.infer<typeof ParseStatus>;

export const ItemStatus = z.enum(["unread", "archived"]);
export type ItemStatus = z.infer<typeof ItemStatus>;

export const ItemSource = z.enum(["share", "extension", "web", "import", "email", "api"]);
export type ItemSource = z.infer<typeof ItemSource>;

/** List filter used by GET /v1/items?state= (UI "collections": My List / Archive / Favorites / All). */
export const ItemState = z.enum(["unread", "archived", "favorites", "all"]);
export type ItemState = z.infer<typeof ItemState>;

export const ItemSort = z.enum(["newest", "oldest", "shortest", "longest"]);
export type ItemSort = z.infer<typeof ItemSort>;

/**
 * Tag name: trimmed, internal whitespace collapsed to single spaces, 1..64 chars, case-insensitively
 * unique per user (the server keeps the casing of the first writer / latest rename).
 */
export function normalizeTagName(name: string): string {
  return name.normalize("NFC").trim().replace(/\s+/g, " ");
}

/**
 * Case-insensitive identity of a tag (stored as `tags.name_key`, unique among live tags).
 * Full Unicode lower-casing (SQLite NOCASE folds ASCII only, so never rely on it for tags).
 */
export function tagKey(name: string): string {
  return normalizeTagName(name).toLowerCase();
}

export const TagName = z
  .string()
  .transform(normalizeTagName)
  .pipe(z.string().min(1).max(LIMITS.maxTagLength));

export const TagNames = z.array(TagName).max(LIMITS.maxTagsPerItem);

/** Item as sent on the wire (GET /v1/items, sync pull, POST /v1/items …). */
export const Item = z.object({
  id: z.uuid(),
  /** URL as saved. */
  url: z.string(),
  /** normalizeUrl(url) — dedupe key. */
  canonicalUrl: z.string(),
  title: z.string().nullable(),
  excerpt: z.string().nullable(),
  siteName: z.string().nullable(),
  author: z.string().nullable(),
  lang: z.string().nullable(),
  /**
   * Signed URL of the 400px thumbnail (content origin), or null. Signed fresh in every response and
   * expires like other content URLs (24 h) — a convenience for list views; long-lived clients use leadImageKey.
   */
  leadImageUrl: z.string().nullable(),
  /** Thumbnail path relative to the content dir (normally "thumb.webp"), or null. URL = content `baseUrl` + key. */
  leadImageKey: z.string().nullable(),
  wordCount: z.number().int().nullable(),
  readingMinutes: z.number().int().nullable(),
  /** Parsed content package id (null until parsed). */
  contentId: z.uuid().nullable(),
  /** true if content came from captured (logged-in) HTML; stored under private/{userId}/. */
  contentPrivate: z.boolean(),
  parseStatus: ParseStatus,
  parseError: z.string().nullable(),
  status: ItemStatus,
  isFavorite: z.boolean(),
  /** Reading progress 0..1. */
  progress: z.number().min(0).max(1),
  /** Paragraph index (font-size independent), or null. */
  progressAnchor: z.number().int().nonnegative().nullable(),
  savedAt: EpochMs,
  archivedAt: EpochMs.nullable(),
  lastReadAt: EpochMs.nullable(),
  source: ItemSource.nullable(),
  /** Tag names (present pairs only), sorted case-insensitively. */
  tags: z.array(z.string()),
  /** Last change seq (sync). */
  seq: z.number().int().nonnegative(),
});
export type Item = z.infer<typeof Item>;

export const Tag = z.object({
  id: z.uuid(),
  name: z.string(),
  /** Number of non-deleted items carrying the tag (present only in GET /v1/tags). */
  count: z.number().int().nonnegative().optional(),
  seq: z.number().int().nonnegative(),
});
export type Tag = z.infer<typeof Tag>;

export const JobKind = z.enum(["import", "export"]);
export const JobStatus = z.enum(["queued", "running", "done", "failed"]);
export const ImportFormat = z.enum(["pocket_csv", "pocket_html", "instapaper_csv", "netscape_html"]);
export type ImportFormat = z.infer<typeof ImportFormat>;
export const ExportFormat = z.enum(["csv", "json"]);
export type ExportFormat = z.infer<typeof ExportFormat>;

/** Import/export job (D1 `jobs` row). */
export const Job = z.object({
  id: z.uuid(),
  kind: JobKind,
  status: JobStatus,
  format: z.string().nullable(),
  /** Rows found in the file (null until parsed). */
  total: z.number().int().nonnegative().nullable(),
  /** Rows processed so far (inserted + duplicates + skipped). */
  done: z.number().int().nonnegative(),
  /** Rows skipped (invalid URL etc.). */
  skipped: z.number().int().nonnegative(),
  error: z.string().nullable(),
  createdAt: EpochMs,
  updatedAt: EpochMs,
});
export type Job = z.infer<typeof Job>;

export const User = z.object({
  id: z.string(),
  email: z.string(),
  name: z.string().nullable(),
  emailVerified: z.boolean(),
  createdAt: EpochMs,
});
export type User = z.infer<typeof User>;
