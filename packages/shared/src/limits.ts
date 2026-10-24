/** Contract limits shared by server and clients. Documented in docs/api.md "Limits". */
export const LIMITS = {
  /** Max ops in one POST /v1/sync/push. */
  maxOpsPerPush: 500,
  /** GET /v1/sync/pull page size. */
  defaultPullLimit: 500,
  maxPullLimit: 1000,
  /** GET /v1/items page size. */
  defaultListLimit: 30,
  maxListLimit: 100,
  maxUrlLength: 4096,
  maxTitleLength: 1000,
  maxTagLength: 64,
  maxTagsPerItem: 100,
  maxSearchLength: 200,
  /** Rendered HTML sent with POST /v1/items (UTF-8 bytes of the string). */
  maxHtmlBytes: 5 * 1024 * 1024,
  /** Max request body for POST /v1/items (JSON incl. html). */
  maxSaveBodyBytes: 6 * 1024 * 1024,
  /** POST /v1/items/pdf body (one PDF file). */
  maxPdfBytes: 50 * 1024 * 1024,
  /** Sum of fileSize over a user's live PDF items; an upload beyond it → 409 storage_full. */
  maxPdfStorageBytes: 2 * 1024 * 1024 * 1024,
  /** Uploaded file name length (characters); longer names are truncated, keeping the extension. */
  maxFileNameLength: 255,
  /** Import upload size. */
  maxImportBytes: 20 * 1024 * 1024,
  maxImportItems: 50_000,
  /** Server clamps op `at` values further than this into the future to `now + maxClockSkewMs`. */
  maxClockSkewMs: 5 * 60 * 1000,
  /** Tombstones (deleted items/tags) kept this long; older cursors get 410 resync_required. */
  tombstoneTtlMs: 180 * 24 * 60 * 60 * 1000,
  /** applied_ops idempotency records kept this long. */
  appliedOpsTtlMs: 30 * 24 * 60 * 60 * 1000,
  /** Signed content URL lifetime (seconds). */
  contentUrlTtlSec: 24 * 60 * 60,
} as const;

/** Reading-time estimate used by the parser: 230 wpm, min 1 minute for non-empty text. */
export function readingMinutes(wordCount: number): number {
  return wordCount <= 0 ? 0 : Math.max(1, Math.round(wordCount / 230));
}

/**
 * `progressAnchor` = 0-based index of the first element matching this selector (document order,
 * `querySelectorAll` on article.html's body) whose box is at or below the top of the viewport.
 * Web reader and native apps MUST count with exactly this selector so anchors are portable.
 */
export const PROGRESS_ANCHOR_SELECTOR = "p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,figure";
