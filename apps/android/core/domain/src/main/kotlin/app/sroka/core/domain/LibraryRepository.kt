package app.sroka.core.domain

import androidx.paging.PagingData
import app.sroka.core.model.Item
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryCounts
import app.sroka.core.model.SaveResult
import app.sroka.core.model.SearchResult
import app.sroka.core.model.SearchScope
import kotlinx.coroutines.flow.Flow

/**
 * The user's library, local-first (DECISIONS A7). Reads come from Room only; every write updates the
 * local rows and queues a sync op in one transaction, then requests a debounced sync. No method waits
 * for the network, so everything works offline. Writes to an unknown/deleted item id are no-ops.
 */
interface LibraryRepository {

    /** Paged list rows for [query] (tab or tag filter, optional FTS search, sort). */
    fun pagedItems(query: ItemQuery): Flow<PagingData<ItemSummary>>

    /**
     * Full-text search (local FTS only, works offline) over [scope], newest first. Blank / symbol-only
     * [query] yields an empty list. Hits carry a body snippet with match ranges (R8).
     */
    fun search(query: String, scope: SearchScope): Flow<PagingData<SearchResult>>

    /** Total number of hits [search] would return for [query] in [scope] (0 for a blank / symbol-only query). */
    fun searchCount(query: String, scope: SearchScope): Flow<Int>

    /** One item with full detail, or null once it no longer exists locally. */
    fun observeItem(id: String): Flow<Item?>

    /** Counts for tab badges / empty states. */
    fun observeCounts(): Flow<LibraryCounts>

    /**
     * Saves [url] (any text containing a URL is NOT accepted here; extract it first with
     * `extractFirstUrl`). Re-adds an existing item with the same canonical URL instead of duplicating.
     */
    suspend fun save(
        url: String,
        title: String? = null,
        tags: List<String> = emptyList(),
        source: SaveSource = SaveSource.SHARE,
    ): SaveResult

    /** Archive ([ItemStatus.ARCHIVED]) or move back to My List ([ItemStatus.UNREAD]). */
    suspend fun setStatus(id: String, status: ItemStatus)

    suspend fun setFavorite(id: String, favorite: Boolean)

    /** Reading position: [progress] 0..1 and the block-element [anchor] (DECISIONS A10). Coalesced. */
    suspend fun setProgress(id: String, progress: Float, anchor: Int?)

    /** User title; null or blank clears it (server falls back to the parsed title). */
    suspend fun setTitle(id: String, title: String?)

    /** Replaces the item's tags with [names] (normalized, deduplicated by tag key). */
    suspend fun setTags(id: String, names: List<String>)

    /** Deletes the item and its downloaded files. */
    suspend fun delete(id: String)

    /** Asks the server to parse the article again (parse status becomes PENDING locally). */
    suspend fun refresh(id: String)
}

/** Where a save came from; maps to the wire `source` (api.md §4.1). */
enum class SaveSource(val wire: String) {
    /** Android share sheet. */
    SHARE("share"),

    /** Typed or pasted in the app's "Add" dialog. */
    MANUAL("web"),
}
