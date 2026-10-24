package app.sroka.core.database.dao

// SQL fragments shared by the list/search queries (annotation arguments must be compile-time constants).

internal const val ROW_COLUMNS = """
SELECT i.id AS id, i.title AS title, i.url AS url, substr(i.excerpt, 1, 200) AS excerpt,
  i.reading_minutes AS reading_minutes, i.status AS status, i.is_favorite AS is_favorite,
  i.progress AS progress, i.parse_status AS parse_status, i.saved_at AS saved_at,
  i.content_id AS content_id, cf.content_id AS file_content_id, cf.state AS file_state,
  cf.thumb_path AS thumb_path,
  (SELECT group_concat(name, char(31)) FROM
     (SELECT name FROM item_tags WHERE item_id = i.id ORDER BY name_key)) AS tags,
  (SELECT po.type FROM pending_ops po WHERE po.item_id = i.id AND po.type != 'item.setProgress'
     ORDER BY po.local_seq DESC LIMIT 1) AS pending_type,
  i.kind AS kind, i.file_size AS file_size
"""

internal const val LIST_FROM = """
FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id
"""

internal const val SEARCH_FROM = """
FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid
LEFT JOIN content_files cf ON cf.item_id = i.id
"""

// Scope fragments: one concrete WHERE per scope so SQLite can plan with the status / favorite / tag
// indexes (a single OR'ed parameterized filter forces a full scan plus temp B-tree).

/** Tab view by status (`:status`). */
internal const val SCOPE_STATUS = "WHERE i.status = :status"

/** Favorites tab. */
internal const val SCOPE_FAV = "WHERE i.is_favorite = 1"

/** Tag view: any status, driven by the `item_tags(name_key)` index. */
internal const val FROM_TAG = """
FROM item_tags t JOIN items i ON i.id = t.item_id LEFT JOIN content_files cf ON cf.item_id = i.id
"""
internal const val SCOPE_TAG = "WHERE t.name_key = :tagKey"

/** Search variants: the FTS match drives the plan, the scope only narrows. */
internal const val SEARCH_TAG_FROM = """
FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid
JOIN item_tags t ON t.item_id = i.id
LEFT JOIN content_files cf ON cf.item_id = i.id
"""
internal const val MATCH = "items_fts MATCH :match"

internal const val ORDER_NEWEST = "ORDER BY i.saved_at DESC, i.id DESC"
internal const val ORDER_OLDEST = "ORDER BY i.saved_at ASC, i.id ASC"
internal const val ORDER_SHORTEST = "ORDER BY (i.word_count IS NULL), i.word_count ASC, i.saved_at DESC, i.id DESC"
internal const val ORDER_LONGEST = "ORDER BY (i.word_count IS NULL), i.word_count DESC, i.saved_at DESC, i.id DESC"

internal const val DETAIL_SELECT = """
SELECT i.*, cf.content_id AS file_content_id, cf.state AS file_state, cf.thumb_path AS thumb_path,
  (SELECT group_concat(name, char(31)) FROM
     (SELECT name FROM item_tags WHERE item_id = i.id ORDER BY name_key)) AS tags
FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id
"""

// ---- R8 search: summary columns + FTS4 snippet of the body and offsets() (which columns matched) ----

/** Private-use marker characters wrapped around matched terms by `snippet()`. */
internal const val HL_START = '\uE000'
internal const val HL_END = '\uE001'

/** `items_fts` column order: title 0, excerpt 1, site_name 2, tags 3, body 4. */
internal const val FTS_BODY_COLUMN = 4

internal const val SEARCH_COLUMNS = """$ROW_COLUMNS,
  snippet(items_fts, '$HL_START', '$HL_END', '…', $FTS_BODY_COLUMN, 12) AS snippet,
  offsets(items_fts) AS offsets
"""
