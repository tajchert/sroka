package app.sroka.core.data.repository

import androidx.paging.Pager
import androidx.paging.PagingConfig
import androidx.paging.PagingData
import androidx.paging.map
import app.sroka.core.common.di.Dispatcher
import app.sroka.core.common.di.SrokaDispatchers
import app.sroka.core.data.content.ContentPaths
import app.sroka.core.data.ops.OpWriter
import app.sroka.core.data.ops.WireOp
import app.sroka.core.database.FtsQuery
import app.sroka.core.database.dao.ItemDao
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.SaveSource
import app.sroka.core.domain.SyncController
import app.sroka.core.model.Item
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryCounts
import app.sroka.core.model.MAX_TAGS_PER_ITEM
import app.sroka.core.model.MAX_TAG_LENGTH
import app.sroka.core.model.MAX_URL_LENGTH
import app.sroka.core.model.clampTitle
import app.sroka.core.model.SaveResult
import app.sroka.core.model.SearchResult
import app.sroka.core.model.SearchScope
import app.sroka.core.model.UrlNormalizer
import app.sroka.core.model.newUuidV7
import app.sroka.core.model.normalizeTagName
import app.sroka.core.model.tagKey
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/** Local-first library (DECISIONS A7): every write = Room rows + FTS + pending op in one transaction. */
@Singleton
internal class LibraryRepositoryImpl @Inject constructor(
    private val itemDao: ItemDao,
    private val writer: OpWriter,
    private val syncController: SyncController,
    private val paths: ContentPaths,
    @Dispatcher(SrokaDispatchers.IO) private val io: CoroutineDispatcher,
) : LibraryRepository {

    override fun pagedItems(query: ItemQuery): Flow<PagingData<ItemSummary>> =
        Pager(PagingConfig(pageSize = PAGE_SIZE, enablePlaceholders = false)) { itemDao.pagedItems(query) }
            .flow
            .map { page -> page.map { it.toSummary() } }

    override fun search(query: String, scope: SearchScope): Flow<PagingData<SearchResult>> {
        val match = FtsQuery.build(query) ?: return flowOf(PagingData.empty())
        return Pager(PagingConfig(pageSize = PAGE_SIZE, enablePlaceholders = false)) {
            when (scope) {
                SearchScope.ALL -> itemDao.searchAll(match)
                SearchScope.ARCHIVE -> itemDao.searchArchived(match)
                SearchScope.FAVORITES -> itemDao.searchFavorites(match)
            }
        }.flow.map { page -> page.map { it.toSearchResult() } }
    }

    override fun observeItem(id: String): Flow<Item?> =
        itemDao.observeItem(id).map { it?.toItem() }.distinctUntilChanged()

    override fun observeCounts(): Flow<LibraryCounts> =
        itemDao.observeCounts().map { LibraryCounts(it.unread, it.archived, it.favorites) }.distinctUntilChanged()

    override suspend fun save(url: String, title: String?, tags: List<String>, source: SaveSource): SaveResult {
        val trimmed = url.trim()
        if (trimmed.length > MAX_URL_LENGTH) return SaveResult.InvalidUrl
        val canonical = UrlNormalizer.normalize(trimmed) ?: return SaveResult.InvalidUrl
        var result: SaveResult = SaveResult.InvalidUrl
        writer.write { now ->
            val existing = itemDao.findByCanonicalUrl(canonical)
            val id = existing?.id ?: newUuidV7(now)
            result = SaveResult.Saved(id, alreadySaved = existing != null)
            listOf(
                WireOp.Add(
                    opId = writer.newOpId(now),
                    itemId = id,
                    at = now,
                    url = trimmed,
                    title = clampTitle(title),
                    tags = normalizeTags(tags),
                    source = source.wire,
                    savedAt = now,
                ),
            )
        }
        syncController.requestSync()
        return result
    }

    override suspend fun setStatus(id: String, status: ItemStatus) =
        write { now -> listOf(WireOp.SetStatus(writer.newOpId(now), id, now, status)) }

    override suspend fun setFavorite(id: String, favorite: Boolean) =
        write { now -> listOf(WireOp.SetFavorite(writer.newOpId(now), id, now, favorite)) }

    override suspend fun setProgress(id: String, progress: Float, anchor: Int?) =
        write { now -> listOf(WireOp.SetProgress(writer.newOpId(now), id, now, progress.coerceIn(0f, 1f), anchor)) }

    override suspend fun setTitle(id: String, title: String?) =
        write { now -> listOf(WireOp.SetTitle(writer.newOpId(now), id, now, clampTitle(title))) }

    override suspend fun setTags(id: String, names: List<String>) = write { now ->
        if (itemDao.getItem(id) == null) return@write emptyList()
        val current = itemDao.tagNames(id)
        val desired = normalizeTags(names)
        val currentKeys = current.mapTo(HashSet()) { tagKey(it) }
        val desiredKeys = desired.mapTo(HashSet()) { tagKey(it) }
        current.filter { tagKey(it) !in desiredKeys }.map { WireOp.Tag(writer.newOpId(now), id, now, it, present = false) } +
            desired.filter { tagKey(it) !in currentKeys }.map { WireOp.Tag(writer.newOpId(now), id, now, it, present = true) }
    }

    override suspend fun delete(id: String) {
        val deleted = writer.write { now -> listOf(WireOp.Delete(writer.newOpId(now), id, now)) }
        if (deleted) {
            withContext(io) { paths.deleteItemFiles(id) }
            syncController.requestSync()
        }
    }

    override suspend fun refresh(id: String) =
        write { now -> listOf(WireOp.Refresh(writer.newOpId(now), id, now)) }

    private suspend fun write(build: suspend (Long) -> List<WireOp>) {
        if (writer.write(build)) syncController.requestSync()
    }

    private companion object {
        const val PAGE_SIZE = 40
    }
}

/** Normalized, valid (1–64 chars), de-duplicated by tag key, at most [MAX_TAGS_PER_ITEM]. */
internal fun normalizeTags(names: List<String>): List<String> =
    names.map(::normalizeTagName)
        .filter { it.isNotEmpty() && it.length <= MAX_TAG_LENGTH }
        .distinctBy(::tagKey)
        .take(MAX_TAGS_PER_ITEM)
