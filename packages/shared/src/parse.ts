import { z } from "zod";
import { ParseStatus } from "./model.ts";

/** Bump when extraction output changes meaningfully (invalidates the shared D1 content cache). */
export const PARSER_VERSION = 1;

/** Message on queue `sroka-parse` (producer: sroka-api, consumer: sroka-parser). */
export const ParseJobSchema = z.object({
  userId: z.string().min(1),
  itemId: z.uuid(),
  /** URL as saved (parser normalizes again for the cache lookup). */
  url: z.string().min(1),
  /** R2 key of captured HTML (`raw/{userId}/{itemId}.html.gz`, gzip). Present → private content. */
  rawKey: z.string().optional(),
  /** Skip the shared cache (item.refresh). */
  force: z.boolean().optional(),
});
export type ParseJob = z.infer<typeof ParseJobSchema>;

/** Argument of the RPC `LibraryDO.markParsed(itemId, result)`. */
export const ParseResultSchema = z.object({
  status: ParseStatus.exclude(["pending"]),
  /** Content package id (null/absent when failed). */
  contentId: z.uuid().optional(),
  /** true → R2 prefix private/{userId}/{contentId}/, false → content/{contentId}/. */
  contentPrivate: z.boolean(),
  title: z.string().nullable(),
  excerpt: z.string().nullable(),
  siteName: z.string().nullable(),
  author: z.string().nullable(),
  lang: z.string().nullable(),
  wordCount: z.number().int().nonnegative().nullable(),
  readingMinutes: z.number().int().nonnegative().nullable(),
  /**
   * Thumbnail file path RELATIVE to the content dir (normally "thumb.webp"), or absent.
   * The API turns it into a signed `leadImageUrl`.
   */
  leadImageKey: z.string().optional(),
  /** Short machine-ish reason for failed/partial, e.g. "http_404", "timeout", "not_html", "extract_failed". */
  error: z.string().optional(),
  parserVersion: z.number().int().positive(),
});
export type ParseResult = z.infer<typeof ParseResultSchema>;

/** Offline package manifest.json (design §7.3). */
export const PackageManifest = z.object({
  format: z.literal(1),
  contentId: z.uuid(),
  parserVersion: z.number().int(),
  title: z.string().nullable(),
  byline: z.string().nullable(),
  siteName: z.string().nullable(),
  lang: z.string().nullable(),
  wordCount: z.number().int(),
  readingMinutes: z.number().int(),
  files: z.array(z.object({ path: z.string(), sha256: z.string(), bytes: z.number().int() })),
});
export type PackageManifest = z.infer<typeof PackageManifest>;

/** R2 key helpers (design §7.3 / decisions D6–D7). */
export const r2Keys = {
  contentDir: (contentId: string, privateUserId?: string | null) =>
    privateUserId ? `private/${privateUserId}/${contentId}/` : `content/${contentId}/`,
  raw: (userId: string, itemId: string) => `raw/${userId}/${itemId}.html.gz`,
  upload: (userId: string, importId: string) => `uploads/${userId}/${importId}`,
  privatePrefix: (userId: string) => `private/${userId}/`,
  rawPrefix: (userId: string) => `raw/${userId}/`,
  uploadsPrefix: (userId: string) => `uploads/${userId}/`,
} as const;
