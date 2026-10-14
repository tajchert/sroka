package app.sroka.core.database.dao

// SQL fragments shared by the list/search queries (annotation arguments must be compile-time constants).

internal const val ROW_COLUMNS = """
SELECT i.id AS id, i.title AS title, i.url AS url, substr(i.excerpt, 1, 200) AS excerpt,
  i.reading_minutes AS reading_minutes, i.status AS status, i.is_favorite AS is_favorite,
  i.progress AS progress, i.parse_status AS parse_status, i.saved_at AS saved_at,
  i.content_id AS content_id, cf.content_id AS file_content_id, cf.state AS file_state,
  cf.thumb_path AS thumb_path,
  (SELECT group_concat(name, char(31)) FROM
     (SELECT name FROM item_tags WHERE item_id = i.id ORDER BY name_key)) AS tags
"""

internal const val LIST_FROM = """
FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id
"""

internal const val SEARCH_FROM = """
FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid
LEFT JOIN content_files cf ON cf.item_id = i.id
"""

/** Tag view (any status) or tab view (status and/or favorites). */
internal const val FILTER = """
((:tagKey IS NULL AND (:status IS NULL OR i.status = :status) AND (:favoritesOnly = 0 OR i.is_favorite = 1))
 OR (:tagKey IS NOT NULL AND EXISTS (SELECT 1 FROM item_tags t WHERE t.item_id = i.id AND t.name_key = :tagKey)))
"""

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
