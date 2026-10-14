import type { Item, ItemSource, ItemStatus, ParseStatus } from "@sroka/shared";
import { tagKey } from "@sroka/shared";

export type ItemRow = {
  id: string;
  url: string;
  canonical_url: string;
  url_hash: string;
  domain: string;
  title: string | null;
  user_title: string | null;
  excerpt: string | null;
  site_name: string | null;
  author: string | null;
  lang: string | null;
  lead_image_key: string | null;
  word_count: number | null;
  reading_minutes: number | null;
  content_id: string | null;
  content_private: number;
  parse_status: string;
  parse_error: string | null;
  parse_gen: number;
  status: string;
  is_favorite: number;
  progress: number;
  progress_anchor: number | null;
  saved_at: number;
  archived_at: number | null;
  last_read_at: number | null;
  deleted_at: number | null;
  source: string | null;
  clock: string;
  seq: number;
  fts_rowid: number | null;
  /** v2: server time of the delete (purge reference); deleted_at is the client stamp. */
  tombstoned_at: number | null;
  /** v2: server time of the last parse request (stuck-pending sweep). */
  parse_requested_at: number | null;
  parse_raw_key: string | null;
};

export type TagRow = {
  id: string;
  name: string;
  name_key: string;
  created_at: number;
  deleted_at: number | null;
  seq: number;
};

export type PairRow = { present: number; at: number; dev: string };

/** Item without the signed leadImageUrl (added by the DO layer, which knows env + userId). */
export type ItemData = Omit<Item, "leadImageUrl">;

/** Case-insensitive, deterministic tag name order (by tagKey, then raw name). */
export function compareTagNames(a: string, b: string): number {
  const ka = tagKey(a);
  const kb = tagKey(b);
  if (ka !== kb) return ka < kb ? -1 : 1;
  return a < b ? -1 : a > b ? 1 : 0;
}

export function sortTagNames(names: string[]): string[] {
  return names.sort(compareTagNames);
}

export function rowToItemData(r: ItemRow, tags: string[]): ItemData {
  return {
    id: r.id,
    url: r.url,
    canonicalUrl: r.canonical_url,
    title: r.user_title ?? r.title,
    excerpt: r.excerpt,
    siteName: r.site_name,
    author: r.author,
    lang: r.lang,
    leadImageKey: r.lead_image_key,
    wordCount: r.word_count,
    readingMinutes: r.reading_minutes,
    contentId: r.content_id,
    contentPrivate: r.content_private === 1,
    parseStatus: r.parse_status as ParseStatus,
    parseError: r.parse_error,
    status: r.status as ItemStatus,
    isFavorite: r.is_favorite === 1,
    progress: r.progress,
    progressAnchor: r.progress_anchor,
    savedAt: r.saved_at,
    archivedAt: r.archived_at,
    lastReadAt: r.last_read_at,
    source: r.source as ItemSource | null,
    tags: sortTagNames(tags),
    seq: r.seq,
  };
}
