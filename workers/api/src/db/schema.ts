import { index, integer, primaryKey, sqliteTable, text } from "drizzle-orm/sqlite-core";

/**
 * Public (shared) parsed content, one row per `content/{id}/` R2 dir (design §7.2, api.md §9). Rows with
 * `cacheable = 1` form the shared parse cache; every public dir has a row so the GC (parser `src/gc.ts`) can
 * collect it. `ref_count` is a cache of COUNT(content_refs) written by LibraryDO ref flushes; the truth is
 * `content_refs`. `last_used_at` (insert, cache hit, attach/detach) starts the GC grace period; `gc_at` marks a
 * row whose R2 dir is being deleted (excluded from the cache).
 */
export const content = sqliteTable(
  "content",
  {
    id: text("id").primaryKey(),
    urlHash: text("url_hash").notNull(),
    canonicalUrl: text("canonical_url").notNull(),
    parserVersion: integer("parser_version").notNull(),
    status: text("status").notNull(), // ok|partial|failed
    title: text("title"),
    wordCount: integer("word_count"),
    lang: text("lang"),
    bytes: integer("bytes"),
    refCount: integer("ref_count").default(0),
    parsedAt: integer("parsed_at").notNull(),
    cacheable: integer("cacheable").notNull().default(1),
    lastUsedAt: integer("last_used_at").notNull().default(0),
    gcAt: integer("gc_at"),
  },
  (t) => [index("content_url").on(t.urlHash, t.parserVersion, t.parsedAt), index("content_last_used").on(t.lastUsedAt)],
);

/**
 * Which users' libraries reference which public content (api.md §9 "Content references"). Maintained by each
 * LibraryDO from its own items (outbox flush, at-least-once, idempotent): a row exists while at least one live
 * item of that user has `content_id = content_id AND content_private = 0`.
 */
export const contentRefs = sqliteTable(
  "content_refs",
  {
    contentId: text("content_id").notNull(),
    userId: text("user_id").notNull(),
    at: integer("at").notNull(),
  },
  (t) => [primaryKey({ columns: [t.contentId, t.userId] }), index("content_refs_user").on(t.userId)],
);

/** Maintenance state (shared-content GC backfill: keys `gc_backfill`, `gc_backfill_cursor`, `gc_backfill_done`). */
export const gcState = sqliteTable("gc_state", {
  k: text("k").primaryKey(),
  v: text("v").notNull(),
});

/** Import/export job status. Design §7.2 + format, skipped (api.md §15). */
export const jobs = sqliteTable(
  "jobs",
  {
    id: text("id").primaryKey(),
    userId: text("user_id"),
    kind: text("kind"),
    status: text("status"),
    format: text("format"),
    total: integer("total"),
    done: integer("done"),
    skipped: integer("skipped").notNull().default(0),
    error: text("error"),
    createdAt: integer("created_at"),
    updatedAt: integer("updated_at"),
  },
  (t) => [index("jobs_user").on(t.userId, t.createdAt)],
);

/** Per-email OTP throttle counters (src/auth-throttle.ts). key = `{kind}:{window}:{email}:{bucket}`. */
export const authThrottle = sqliteTable(
  "auth_throttle",
  {
    key: text("key").primaryKey(),
    count: integer("count").notNull().default(0),
    expiresAt: integer("expires_at").notNull(),
  },
  (t) => [index("auth_throttle_expires").on(t.expiresAt)],
);

/**
 * One row per finished parse job (parser `src/attempts.ts`, decisions D10): the final outcome of a queue delivery
 * (ok/partial/failed, incl. shared-cache hits; transient retries are not recorded) and DLQ failures. Retention 30
 * days (parser weekly cron). `url` = canonical URL for public content, NULL for captured/private content.
 * `user_hash` = sha256(userId) hex prefix 16.
 */
export const parseAttempts = sqliteTable(
  "parse_attempts",
  {
    id: text("id").primaryKey(),
    createdAt: integer("created_at").notNull(),
    userHash: text("user_hash").notNull(),
    itemId: text("item_id").notNull(),
    domain: text("domain").notNull(),
    url: text("url"),
    status: text("status").notNull(), // ok|partial|failed
    errorCode: text("error_code"),
    errorDetail: text("error_detail"),
    method: text("method").notNull(), // fetch|render|capture|cache
    fallbackOutcome: text("fallback_outcome").notNull(), // none|ok|partial|failed|budget|disabled
    httpStatus: integer("http_status"),
    textChars: integer("text_chars"),
    wordCount: integer("word_count"),
    images: integer("images"),
    durationMs: integer("duration_ms"),
    renderMs: integer("render_ms"),
    attempt: integer("attempt").notNull(),
    parserVersion: integer("parser_version").notNull(),
    ruleApplied: integer("rule_applied").notNull().default(0),
  },
  (t) => [
    index("parse_attempts_created").on(t.createdAt),
    index("parse_attempts_domain").on(t.domain, t.createdAt),
    index("parse_attempts_status").on(t.status, t.createdAt),
  ],
);

/** Browser Run daily render budget counters (parser `src/render.ts`), key `u:{userHash}:{day}` | `g:{day}`. */
export const renderBudget = sqliteTable(
  "render_budget",
  {
    key: text("key").primaryKey(),
    count: integer("count").notNull().default(0),
    expiresAt: integer("expires_at").notNull(),
  },
  (t) => [index("render_budget_expires").on(t.expiresAt)],
);
