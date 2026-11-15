package app.sroka.core.model

/**
 * What a library list shows. Every set filter narrows the list (AND):
 * - [tab]: My List (unread), Archive or Favorites (any status); null = every live item (tag pages).
 * - [tag]: items carrying this tag (case-insensitive).
 * - [favoritesOnly]: favorite items only.
 * - [maxReadingMinutes]: items with a known reading time of at most this many minutes.
 * - [search]: local full-text search.
 */
data class ItemQuery(
    val tab: LibraryTab?,
    val tag: String? = null,
    val search: String? = null,
    val sort: SortOrder = SortOrder.NEWEST,
    val favoritesOnly: Boolean = false,
    val maxReadingMinutes: Int? = null,
)

/** Tag name with the number of live items carrying it. */
data class TagCount(val name: String, val count: Int)

/** Badge counts for the library tabs. */
data class LibraryCounts(val unread: Int = 0, val archived: Int = 0, val favorites: Int = 0)
