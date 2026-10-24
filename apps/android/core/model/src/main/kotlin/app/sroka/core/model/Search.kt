package app.sroka.core.model

/** Which items a search covers (R8). ALL = every live item, any status. */
enum class SearchScope { ALL, ARCHIVE, FAVORITES }

/** Where the query matched. */
enum class MatchIn { TITLE, TEXT, BOTH }

/**
 * One search hit. [snippet] is plain text around the body match (markers stripped), null when the body
 * did not match; [highlights] are the matched ranges (char offsets) inside [snippet].
 */
data class SearchResult(
    val summary: ItemSummary,
    val matchIn: MatchIn,
    val snippet: String?,
    val highlights: List<IntRange>,
)
