package app.sroka.core.data.repository

import app.sroka.core.database.entity.SearchRow
import app.sroka.core.model.MatchIn
import app.sroka.core.model.SearchResult

private const val HL_START = '\uE000'
private const val HL_END = '\uE001'

/** `items_fts` body column index (title 0, excerpt 1, site_name 2, tags 3, body 4). */
private const val BODY_COLUMN = 4

internal fun SearchRow.toSearchResult(): SearchResult {
    val columns = matchedColumns(offsets)
    val inBody = BODY_COLUMN in columns
    // Anything but the body (title, excerpt, site, tags) counts as a metadata match, shown as "title".
    val inMeta = columns.any { it != BODY_COLUMN } || columns.isEmpty()
    val parsed = if (inBody) parseSnippet(snippet) else null
    return SearchResult(
        summary = row.toSummary(),
        matchIn = when {
            inBody && inMeta -> MatchIn.BOTH
            inBody -> MatchIn.TEXT
            else -> MatchIn.TITLE
        },
        snippet = parsed?.first,
        highlights = parsed?.second.orEmpty(),
    )
}

/** Distinct column numbers of an FTS4 `offsets()` string ("col term byteOffset size" groups). */
internal fun matchedColumns(offsets: String?): Set<Int> {
    if (offsets.isNullOrBlank()) return emptySet()
    val nums = offsets.trim().split(' ').mapNotNull { it.toIntOrNull() }
    return nums.filterIndexed { i, _ -> i % 4 == 0 }.toSet()
}

/**
 * Strips the private-use markers of an FTS4 `snippet()` and returns the clean text with the marked
 * ranges (offsets into the clean text). Null when [raw] is null/blank.
 */
internal fun parseSnippet(raw: String?): Pair<String, List<IntRange>>? {
    if (raw.isNullOrBlank()) return null
    val out = StringBuilder(raw.length)
    val ranges = ArrayList<IntRange>()
    var start = -1
    for (c in raw) {
        when (c) {
            HL_START -> start = out.length
            HL_END -> {
                if (start >= 0 && out.length > start) ranges += start until out.length
                start = -1
            }
            else -> out.append(c)
        }
    }
    return out.toString() to ranges
}
