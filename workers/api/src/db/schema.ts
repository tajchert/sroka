import { index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

/** Shared parse cache (public pages only). Design §7.2. */
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
  },
  (t) => [index("content_url").on(t.urlHash, t.parserVersion, t.parsedAt)],
);

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
