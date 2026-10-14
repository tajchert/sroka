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
  /**
   * items.parse_gen at enqueue time (the DO increments it on every enqueue and returns it with the job).
   * Echoed in ParseResult; markParsed ignores results whose parseGen != the item's current parse_gen.
   */
  parseGen: z.number().int().nonnegative(),
});
export type ParseJob = z.infer<typeof ParseJobSchema>;

/**
 * Argument of the RPC `LibraryDO.markParsed(itemId, result)`.
 * Invariant: `contentId` required for ok/partial, absent for failed. A failed result only updates
 * parse_status/parse_error (+seq); it never touches content_id, content_private or metadata.
 */
export const ParseResultSchema = z
  .object({
    status: ParseStatus.exclude(["pending"]),
    /** ParseJob.parseGen echoed back (stale results are ignored). */
    parseGen: z.number().int().nonnegative(),
    /** Content package id: required for ok/partial, absent for failed. */
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
  })
  .superRefine((r, ctx) => {
    if (r.status === "failed" ? r.contentId !== undefined : r.contentId === undefined) {
      ctx.addIssue({
        code: "custom",
        path: ["contentId"],
        message: r.status === "failed" ? "contentId must be absent when failed" : "contentId required when ok/partial",
      });
    }
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
