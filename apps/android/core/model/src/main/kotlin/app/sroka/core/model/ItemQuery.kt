package app.sroka.core.model

/**
 * What a library list shows. When [tag] is set the [tab] filter is ignored: a tag view lists all
 * live items carrying that tag, any status. [search] runs against local full-text search.
 */
data class ItemQuery(
    val tab: LibraryTab,
    val tag: String? = null,
    val search: String? = null,
    val sort: SortOrder = SortOrder.NEWEST,
)

/** Tag name with the number of live items carrying it. */
data class TagCount(val name: String, val count: Int)

/** Badge counts for the library tabs. */
data class LibraryCounts(val unread: Int = 0, val archived: Int = 0, val favorites: Int = 0)
