package app.sroka.core.testing.fake

import androidx.paging.LoadState
import androidx.paging.LoadStates
import androidx.paging.PagingData
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.SaveSource
import app.sroka.core.model.Item
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryCounts
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.MatchIn
import app.sroka.core.model.SaveResult
import app.sroka.core.model.SearchResult
import app.sroka.core.model.SearchScope
import app.sroka.core.model.SortOrder
import app.sroka.core.model.UrlNormalizer
import app.sroka.core.model.newUuidV7
import app.sroka.core.model.normalizeTagName
import app.sroka.core.model.tagKey
import app.sroka.core.model.toSummary
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update

/** In-memory [LibraryRepository]. Seed with [items]; inspect [items] after actions. */
class FakeLibraryRepository(initial: List<Item> = emptyList()) : LibraryRepository {

    val items = MutableStateFlow(initial)

    /** Last query passed to [pagedItems]. */
    var lastQuery: ItemQuery? = null
        private set

    var now: Long = 1_760_500_000_000L

    override fun pagedItems(query: ItemQuery): Flow<PagingData<ItemSummary>> {
        lastQuery = query
        return items.map { PagingData.from(
                filter(it, query).map(Item::toSummary),
                // Report "loaded" so UIs leave their loading state in tests (empty states render).
                sourceLoadStates = LoadStates(
                    refresh = LoadState.NotLoading(endOfPaginationReached = true),
                    prepend = LoadState.NotLoading(endOfPaginationReached = true),
                    append = LoadState.NotLoading(endOfPaginationReached = true),
                ),
            ) }
    }

    /** The rows [pagedItems] would page through for [query]. */
    fun filter(all: List<Item>, query: ItemQuery): List<Item> {
        val tagKey = query.tag?.let(::tagKey)
        val terms = query.search?.lowercase()?.split(' ')?.filter { it.isNotBlank() }.orEmpty()
        return all
            .filter { item ->
                if (tagKey != null) {
                    item.tags.any { tagKey(it) == tagKey }
                } else {
                    when (query.tab) {
                        LibraryTab.MY_LIST -> item.status == ItemStatus.UNREAD
                        LibraryTab.ARCHIVE -> item.status == ItemStatus.ARCHIVED
                        LibraryTab.FAVORITES -> item.isFavorite
                    }
                }
            }
            .filter { item ->
                val text = listOfNotNull(item.title, item.excerpt, item.siteName, item.url).joinToString(" ").lowercase() +
                    " " + item.tags.joinToString(" ").lowercase()
                terms.all { it in text }
            }
            .let { list ->
                when (query.sort) {
                    SortOrder.NEWEST -> list.sortedByDescending { it.savedAt }
                    SortOrder.OLDEST -> list.sortedBy { it.savedAt }
                    SortOrder.SHORTEST -> list.sortedBy { it.wordCount ?: Int.MAX_VALUE }
                    SortOrder.LONGEST -> list.sortedByDescending { it.wordCount ?: -1 }
                }
            }
    }

    /** Last search passed to [search]. */
    var lastSearch: Pair<String, SearchScope>? = null
        private set

    /**
     * Case-insensitive substring search over title/excerpt/site/tags/url (every term must occur), newest
     * first. The fake has no article body: matches in the excerpt count as TEXT and yield a snippet
     * with highlights.
     */
    override fun search(query: String, scope: SearchScope): Flow<PagingData<SearchResult>> {
        lastSearch = query to scope
        val terms = query.lowercase().split(' ').filter { it.isNotBlank() }
        return items.map { all ->
            val hits = if (terms.isEmpty()) emptyList() else all
                .filter {
                    when (scope) {
                        SearchScope.ALL -> true
                        SearchScope.ARCHIVE -> it.status == ItemStatus.ARCHIVED
                        SearchScope.FAVORITES -> it.isFavorite
                    }
                }
                .mapNotNull { item -> searchResultOf(item, terms) }
                .sortedByDescending { it.summary.savedAt }
            PagingData.from(
                hits,
                sourceLoadStates = LoadStates(
                    refresh = LoadState.NotLoading(endOfPaginationReached = true),
                    prepend = LoadState.NotLoading(endOfPaginationReached = true),
                    append = LoadState.NotLoading(endOfPaginationReached = true),
                ),
            )
        }
    }

    override fun searchCount(query: String, scope: SearchScope): Flow<Int> {
        val terms = query.lowercase().split(' ').filter { it.isNotBlank() }
        return items.map { all ->
            if (terms.isEmpty()) {
                0
            } else {
                all.filter {
                    when (scope) {
                        SearchScope.ALL -> true
                        SearchScope.ARCHIVE -> it.status == ItemStatus.ARCHIVED
                        SearchScope.FAVORITES -> it.isFavorite
                    }
                }.count { searchResultOf(it, terms) != null }
            }
        }
    }

    private fun searchResultOf(item: Item, terms: List<String>): SearchResult? {
        val title = item.displayTitle.lowercase()
        val excerpt = item.excerpt.orEmpty()
        val meta = listOfNotNull(item.siteName, item.url).joinToString(" ").lowercase() + " " +
            item.tags.joinToString(" ").lowercase()
        if (!terms.all { it in title || it in excerpt.lowercase() || it in meta }) return null
        val inTitle = terms.any { it in title } || terms.any { it in meta }
        val ranges = terms.flatMap { t ->
            val lower = excerpt.lowercase()
            val i = lower.indexOf(t)
            if (i >= 0) listOf(i until i + t.length) else emptyList()
        }.sortedBy { it.first }
        val inText = ranges.isNotEmpty()
        return SearchResult(
            summary = item.toSummary(),
            matchIn = when {
                inTitle && inText -> MatchIn.BOTH
                inText -> MatchIn.TEXT
                else -> MatchIn.TITLE
            },
            snippet = excerpt.takeIf { inText },
            highlights = ranges,
        )
    }

    override fun observeNextUnread(): Flow<ItemSummary?> = items.map { list ->
        list.filter { it.status == ItemStatus.UNREAD }.maxByOrNull { it.savedAt }?.toSummary()
    }

    override fun observeItem(id: String): Flow<Item?> = items.map { list -> list.firstOrNull { it.id == id } }

    override fun observeCounts(): Flow<LibraryCounts> = items.map { list ->
        LibraryCounts(
            unread = list.count { it.status == ItemStatus.UNREAD },
            archived = list.count { it.status == ItemStatus.ARCHIVED },
            favorites = list.count { it.isFavorite },
        )
    }

    override suspend fun save(url: String, title: String?, tags: List<String>, source: SaveSource): SaveResult {
        val canonical = UrlNormalizer.normalize(url) ?: return SaveResult.InvalidUrl
        val existing = items.value.firstOrNull { it.canonicalUrl == canonical }
        if (existing != null) {
            update(existing.id) {
                it.copy(status = ItemStatus.UNREAD, archivedAt = null, savedAt = now, tags = mergeTags(it.tags, tags))
            }
            return SaveResult.Saved(existing.id, alreadySaved = true)
        }
        val id = newUuidV7(now)
        items.update {
            it + Item(
                id = id, url = url, canonicalUrl = canonical, title = title, excerpt = null, siteName = null,
                author = null, lang = null, leadImageKey = null, wordCount = null, readingMinutes = null,
                contentId = null, contentPrivate = false, parseStatus = ParseStatus.PENDING, parseError = null,
                status = ItemStatus.UNREAD, isFavorite = false, progress = 0f, progressAnchor = null,
                savedAt = now, archivedAt = null, lastReadAt = null, source = source.wire,
                tags = mergeTags(emptyList(), tags), offline = OfflineState.NONE, thumbnailPath = null,
            )
        }
        return SaveResult.Saved(id, alreadySaved = false)
    }

    override suspend fun setStatus(id: String, status: ItemStatus) = update(id) {
        it.copy(status = status, archivedAt = if (status == ItemStatus.ARCHIVED) now else null)
    }

    override suspend fun setFavorite(id: String, favorite: Boolean) = update(id) { it.copy(isFavorite = favorite) }

    override suspend fun setProgress(id: String, progress: Float, anchor: Int?) = update(id) {
        it.copy(progress = progress.coerceIn(0f, 1f), progressAnchor = anchor, lastReadAt = now)
    }

    override suspend fun setTitle(id: String, title: String?) = update(id) { it.copy(title = title?.takeIf { t -> t.isNotBlank() }) }

    override suspend fun setTags(id: String, names: List<String>) = update(id) { it.copy(tags = mergeTags(emptyList(), names)) }

    override suspend fun delete(id: String) = items.update { list -> list.filterNot { it.id == id } }

    override suspend fun refresh(id: String) = update(id) { it.copy(parseStatus = ParseStatus.PENDING) }

    private fun update(id: String, block: (Item) -> Item) =
        items.update { list -> list.map { if (it.id == id) block(it) else it } }

    private fun mergeTags(current: List<String>, added: List<String>): List<String> =
        (current + added.map(::normalizeTagName).filter { it.isNotEmpty() })
            .distinctBy(::tagKey)
            .sortedBy(::tagKey)
}
