package app.sroka.core.database.dao

// SQL fragments shared by the list/search queries (annotation arguments must be compile-time constants).

import app.sroka.core.database.FtsQuery
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SortOrder
import app.sroka.core.model.tagKey

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
  i.kind AS kind, i.file_size AS file_size, i.parse_error AS parse_error
"""

internal const val LIST_FROM = """
FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id
"""

internal const val SEARCH_FROM = """
FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid
LEFT JOIN content_files cf ON cf.item_id = i.id
"""

internal const val MATCH = "items_fts MATCH :match"

internal const val ORDER_NEWEST = "ORDER BY i.saved_at DESC, i.id DESC"
internal const val ORDER_OLDEST = "ORDER BY i.saved_at ASC, i.id ASC"
internal const val ORDER_SHORTEST = "ORDER BY (i.word_count IS NULL), i.word_count ASC, i.saved_at DESC, i.id DESC"
internal const val ORDER_LONGEST = "ORDER BY (i.word_count IS NULL), i.word_count DESC, i.saved_at DESC, i.id DESC"

/** "Continue reading" progress window (proposal 08). */
internal const val CONTINUE_FROM = 0.05
internal const val CONTINUE_TO = 0.95

/** A built list statement: SQL with `?` placeholders and their arguments (String or Long), in order. */
internal data class ListSql(val sql: String, val args: List<Any>)

/**
 * The library list statement for [query]. Each filter adds one concrete AND condition (never an OR'ed
 * "parameter is null" filter, which forces a full scan), so SQLite can still plan with the status /
 * favorite / tag indexes or let the FTS match drive. Tab literals are inlined; user input is bound.
 */
internal fun itemListSql(query: ItemQuery): ListSql {
    val match = query.search?.let { FtsQuery.build(it) }
    val tagKey = query.tag?.let { tagKey(it) }
    val args = mutableListOf<Any>()
    val where = mutableListOf<String>()
    val from = when {
        match != null -> "FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid" +
            (if (tagKey != null) " JOIN item_tags t ON t.item_id = i.id" else "")
        // Driven by the item_tags(name_key) index.
        tagKey != null -> "FROM item_tags t JOIN items i ON i.id = t.item_id"
        else -> "FROM items i"
    }
    if (match != null) {
        where += MATCH_ARG
        args += match
    }
    if (tagKey != null) {
        where += "t.name_key = ?"
        args += tagKey
    }
    when (query.tab) {
        LibraryTab.MY_LIST -> where += "i.status = 'UNREAD'"
        LibraryTab.ARCHIVE -> where += "i.status = 'ARCHIVED'"
        LibraryTab.FAVORITES -> where += "i.is_favorite = 1"
        null -> Unit
    }
    if (query.favoritesOnly && query.tab != LibraryTab.FAVORITES) where += "i.is_favorite = 1"
    query.maxReadingMinutes?.let {
        where += "i.reading_minutes IS NOT NULL AND i.reading_minutes <= ?"
        args += it.toLong()
    }
    val order = when (query.sort) {
        SortOrder.NEWEST -> ORDER_NEWEST
        SortOrder.OLDEST -> ORDER_OLDEST
        SortOrder.SHORTEST -> ORDER_SHORTEST
        SortOrder.LONGEST -> ORDER_LONGEST
    }
    val whereSql = if (where.isEmpty()) "" else where.joinToString(" AND ", prefix = "WHERE ")
    val sql = listOf(ROW_COLUMNS.trim(), from, "LEFT JOIN content_files cf ON cf.item_id = i.id", whereSql, order)
        .filter { it.isNotEmpty() }
        .joinToString(" ")
    return ListSql(sql, args)
}

private const val MATCH_ARG = "items_fts MATCH ?"

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
