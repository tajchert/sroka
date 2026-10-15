package app.sroka.core.database.dao

import androidx.paging.PagingSource
import androidx.room3.ColumnInfo
import androidx.room3.Dao
import androidx.room3.Insert
import androidx.room3.OnConflictStrategy
import androidx.room3.Query
import androidx.room3.Transaction
import androidx.room3.Upsert
import app.sroka.core.database.FtsQuery
import app.sroka.core.database.entity.CountsRow
import app.sroka.core.database.entity.ItemDetailRow
import app.sroka.core.database.entity.ItemEntity
import app.sroka.core.database.entity.ItemSummaryRow
import app.sroka.core.database.entity.ItemTagEntity
import app.sroka.core.database.entity.TagCountRow
import app.sroka.core.database.entity.TagEntity
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SortOrder
import app.sroka.core.model.tagKey
import kotlinx.coroutines.flow.Flow

/**
 * Items, their tags and the FTS index. Every method that changes an item or its tags keeps
 * `items_fts` in step inside the same transaction. To combine with other tables (e.g. a
 * `pending_ops` insert, A7) wrap calls in `database.withWriteTransaction { }`.
 */
@Dao
interface ItemDao {

    // ---- Paged lists -------------------------------------------------------------------------

    /** The library list for [query]: tab / tag filter, optional FTS search, sort. */
    fun pagedItems(query: ItemQuery): PagingSource<Int, ItemSummaryRow> {
        val tagKey = query.tag?.let { tagKey(it) }
        val match = query.search?.let { FtsQuery.build(it) }
        val sort = query.sort
        return when {
            tagKey != null -> if (match == null) {
                when (sort) {
                    SortOrder.NEWEST -> listTagNewest(tagKey)
                    SortOrder.OLDEST -> listTagOldest(tagKey)
                    SortOrder.SHORTEST -> listTagShortest(tagKey)
                    SortOrder.LONGEST -> listTagLongest(tagKey)
                }
            } else {
                when (sort) {
                    SortOrder.NEWEST -> searchTagNewest(match, tagKey)
                    SortOrder.OLDEST -> searchTagOldest(match, tagKey)
                    SortOrder.SHORTEST -> searchTagShortest(match, tagKey)
                    SortOrder.LONGEST -> searchTagLongest(match, tagKey)
                }
            }
            query.tab == LibraryTab.FAVORITES -> if (match == null) {
                when (sort) {
                    SortOrder.NEWEST -> listFavNewest()
                    SortOrder.OLDEST -> listFavOldest()
                    SortOrder.SHORTEST -> listFavShortest()
                    SortOrder.LONGEST -> listFavLongest()
                }
            } else {
                when (sort) {
                    SortOrder.NEWEST -> searchFavNewest(match)
                    SortOrder.OLDEST -> searchFavOldest(match)
                    SortOrder.SHORTEST -> searchFavShortest(match)
                    SortOrder.LONGEST -> searchFavLongest(match)
                }
            }
            else -> {
                val status = if (query.tab == LibraryTab.ARCHIVE) ItemStatus.ARCHIVED.name else ItemStatus.UNREAD.name
                if (match == null) {
                    when (sort) {
                        SortOrder.NEWEST -> listStatusNewest(status)
                        SortOrder.OLDEST -> listStatusOldest(status)
                        SortOrder.SHORTEST -> listStatusShortest(status)
                        SortOrder.LONGEST -> listStatusLongest(status)
                    }
                } else {
                    when (sort) {
                        SortOrder.NEWEST -> searchStatusNewest(match, status)
                        SortOrder.OLDEST -> searchStatusOldest(match, status)
                        SortOrder.SHORTEST -> searchStatusShortest(match, status)
                        SortOrder.LONGEST -> searchStatusLongest(match, status)
                    }
                }
            }
        }
    }

    @Query("$ROW_COLUMNS $LIST_FROM $SCOPE_STATUS $ORDER_NEWEST")
    fun listStatusNewest(status: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM $SCOPE_STATUS $ORDER_OLDEST")
    fun listStatusOldest(status: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM $SCOPE_STATUS $ORDER_SHORTEST")
    fun listStatusShortest(status: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM $SCOPE_STATUS $ORDER_LONGEST")
    fun listStatusLongest(status: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM $SCOPE_FAV $ORDER_NEWEST")
    fun listFavNewest(): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM $SCOPE_FAV $ORDER_OLDEST")
    fun listFavOldest(): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM $SCOPE_FAV $ORDER_SHORTEST")
    fun listFavShortest(): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM $SCOPE_FAV $ORDER_LONGEST")
    fun listFavLongest(): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $FROM_TAG $SCOPE_TAG $ORDER_NEWEST")
    fun listTagNewest(tagKey: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $FROM_TAG $SCOPE_TAG $ORDER_OLDEST")
    fun listTagOldest(tagKey: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $FROM_TAG $SCOPE_TAG $ORDER_SHORTEST")
    fun listTagShortest(tagKey: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $FROM_TAG $SCOPE_TAG $ORDER_LONGEST")
    fun listTagLongest(tagKey: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.status = :status $ORDER_NEWEST")
    fun searchStatusNewest(match: String, status: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.status = :status $ORDER_OLDEST")
    fun searchStatusOldest(match: String, status: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.status = :status $ORDER_SHORTEST")
    fun searchStatusShortest(match: String, status: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.status = :status $ORDER_LONGEST")
    fun searchStatusLongest(match: String, status: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.is_favorite = 1 $ORDER_NEWEST")
    fun searchFavNewest(match: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.is_favorite = 1 $ORDER_OLDEST")
    fun searchFavOldest(match: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.is_favorite = 1 $ORDER_SHORTEST")
    fun searchFavShortest(match: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.is_favorite = 1 $ORDER_LONGEST")
    fun searchFavLongest(match: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_TAG_FROM WHERE $MATCH AND t.name_key = :tagKey $ORDER_NEWEST")
    fun searchTagNewest(match: String, tagKey: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_TAG_FROM WHERE $MATCH AND t.name_key = :tagKey $ORDER_OLDEST")
    fun searchTagOldest(match: String, tagKey: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_TAG_FROM WHERE $MATCH AND t.name_key = :tagKey $ORDER_SHORTEST")
    fun searchTagShortest(match: String, tagKey: String): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_TAG_FROM WHERE $MATCH AND t.name_key = :tagKey $ORDER_LONGEST")
    fun searchTagLongest(match: String, tagKey: String): PagingSource<Int, ItemSummaryRow>

    // ---- Single item / counts / tags ---------------------------------------------------------

    @Query("$DETAIL_SELECT WHERE i.id = :id")
    fun observeItem(id: String): Flow<ItemDetailRow?>

    @Query("$DETAIL_SELECT WHERE i.id = :id")
    suspend fun getItemDetail(id: String): ItemDetailRow?

    @Query("SELECT * FROM items WHERE id = :id")
    suspend fun getItem(id: String): ItemEntity?

    /** A live item with this canonical URL (for re-adding a saved URL, A7). */
    @Query("SELECT * FROM items WHERE canonical_url = :canonicalUrl LIMIT 1")
    suspend fun findByCanonicalUrl(canonicalUrl: String): ItemEntity?

    @Query(
        """SELECT COALESCE(SUM(CASE WHEN status = 'UNREAD' THEN 1 ELSE 0 END), 0) AS unread,
           COALESCE(SUM(CASE WHEN status = 'ARCHIVED' THEN 1 ELSE 0 END), 0) AS archived,
           COALESCE(SUM(is_favorite), 0) AS favorites FROM items""",
    )
    fun observeCounts(): Flow<CountsRow>

    /** Tag name (display form) with live item count; includes server tags with zero items. */
    @Query(
        """SELECT name, cnt AS count FROM (
             SELECT MIN(name) AS name, name_key, COUNT(*) AS cnt FROM item_tags GROUP BY name_key
             UNION ALL
             SELECT t.name, t.name_key, 0 FROM tags t
               WHERE NOT EXISTS (SELECT 1 FROM item_tags it WHERE it.name_key = t.name_key)
           ) ORDER BY name_key""",
    )
    fun observeTagCounts(): Flow<List<TagCountRow>>

    /** Most recently used tags (by newest item carrying them). */
    @Query(
        """WITH recent AS (SELECT id, saved_at FROM items ORDER BY saved_at DESC LIMIT 500)
           SELECT MIN(it.name) FROM recent r JOIN item_tags it ON it.item_id = r.id
           GROUP BY it.name_key ORDER BY MAX(r.saved_at) DESC, it.name_key LIMIT :limit""",
    )
    fun observeRecentTags(limit: Int): Flow<List<String>>

    @Query("SELECT name FROM item_tags WHERE item_id = :itemId ORDER BY name_key")
    suspend fun tagNames(itemId: String): List<String>

    @Query("SELECT item_id FROM item_tags WHERE name_key = :nameKey")
    suspend fun itemIdsWithTag(nameKey: String): List<String>

    @Transaction
    suspend fun existingIds(ids: List<String>): List<String> =
        ids.chunked(SQL_CHUNK).flatMap { existingIdsChunk(it) }

    @Query("SELECT id FROM items WHERE id IN (:ids)")
    suspend fun existingIdsChunk(ids: List<String>): List<String>

    // ---- Writes ------------------------------------------------------------------------------

    /**
     * Inserts or updates [item], preserving its `fts_rowid` and child rows (tags, content_files),
     * and refreshes its FTS row (title/excerpt/site/tags; downloaded `body` is kept).
     */
    @Transaction
    suspend fun upsertItem(item: ItemEntity) {
        val old = getItem(item.id)
        val rowId = old?.ftsRowId ?: nextFtsRowId()
        upsertRaw(item.copy(ftsRowId = rowId))
        if (old == null || old.indexedFieldsDiffer(item)) refreshFts(item.id)
    }

    /** [upsertItem] plus a full replacement of the item's tags, with one FTS write. */
    @Transaction
    suspend fun upsertItemWithTags(item: ItemEntity, tagNames: List<String>) {
        val old = getItem(item.id)
        val rowId = old?.ftsRowId ?: nextFtsRowId()
        upsertRaw(item.copy(ftsRowId = rowId))
        val wanted = cleanTagRows(item.id, tagNames)
        val tagsChanged = old == null || wanted.sortedBy { it.nameKey }.map { it.name } != tagNames(item.id)
        if (tagsChanged) {
            deleteTagRows(item.id)
            if (wanted.isNotEmpty()) insertTagRows(wanted)
        }
        // refreshFts is itself a no-op when the stored FTS metadata already matches.
        if (old == null || tagsChanged || old.indexedFieldsDiffer(item)) refreshFts(item.id)
    }

    /** Replaces the tags of [itemId] (names are de-duplicated by key; first spelling wins). */
    @Transaction
    suspend fun replaceTags(itemId: String, names: List<String>) {
        if (getItem(itemId) == null) return
        replaceTagRows(itemId, names)
        refreshFts(itemId)
    }

    /** Deletes the item (tags + content_files cascade) and its FTS row. */
    @Transaction
    suspend fun deleteItem(id: String) {
        ftsRowIdOf(id)?.let { deleteFtsRow(it) }
        deleteItemRow(id)
    }

    /**
     * Re-keys a local-only item [fromId] to [toId] (server alias): the row, its FTS rowid and its
     * tags move to the new id; any `content_files` row of [fromId] is dropped (no package yet).
     * Done as copy + move + delete because `item_tags` has a foreign key without ON UPDATE.
     */
    @Transaction
    suspend fun rekeyItem(fromId: String, toId: String) {
        val old = getItem(fromId) ?: return
        if (getItem(toId) != null) return
        // Park the copy on a temporary (negative) rowid: fts_rowid is UNIQUE.
        upsertRaw(old.copy(id = toId, ftsRowId = -old.ftsRowId))
        moveTagRows(fromId, toId)
        deleteItemRow(fromId)
        setFtsRowId(toId, old.ftsRowId)
    }

    @Query("UPDATE item_tags SET item_id = :toId WHERE item_id = :fromId")
    suspend fun moveTagRows(fromId: String, toId: String)

    @Query("UPDATE items SET fts_rowid = :rowId WHERE id = :id")
    suspend fun setFtsRowId(id: String, rowId: Long)

    @Transaction
    suspend fun deleteItems(ids: List<String>) {
        ids.forEach { deleteItem(it) }
    }

    @Transaction
    suspend fun setTitle(id: String, title: String?) {
        updateTitle(id, title)
        refreshFts(id)
    }

    /** Sets the searchable plain-text article body (empty clears it). */
    @Transaction
    suspend fun setFtsBody(itemId: String, body: String) {
        val rowId = ftsRowIdOf(itemId) ?: return
        if (ftsRowExists(rowId) == null) refreshFts(itemId)
        updateFtsBody(rowId, body)
    }

    @Transaction
    suspend fun renameTag(fromKey: String, toName: String) {
        for (id in itemIdsWithTag(fromKey)) {
            val names = tagNames(id).filter { tagKey(it) != fromKey } + toName
            replaceTags(id, names)
        }
        deleteTagRowByKey(fromKey)
    }

    @Transaction
    suspend fun deleteTag(nameKey: String) {
        for (id in itemIdsWithTag(nameKey)) {
            replaceTags(id, tagNames(id).filter { tagKey(it) != nameKey })
        }
        deleteTagRowByKey(nameKey)
    }

    @Query("UPDATE items SET status = :status, archived_at = :archivedAt WHERE id = :id")
    suspend fun setStatus(id: String, status: ItemStatus, archivedAt: Long?)

    @Query("UPDATE items SET is_favorite = :favorite WHERE id = :id")
    suspend fun setFavorite(id: String, favorite: Boolean)

    @Query(
        "UPDATE items SET progress = :progress, progress_anchor = :anchor, last_read_at = :readAt WHERE id = :id",
    )
    suspend fun setProgress(id: String, progress: Float, anchor: Int?, readAt: Long)

    @Query("UPDATE items SET parse_status = :parseStatus, parse_error = NULL WHERE id = :id")
    suspend fun setParseStatus(id: String, parseStatus: app.sroka.core.model.ParseStatus)

    // ---- Server tag rows (pull) --------------------------------------------------------------

    @Upsert
    suspend fun upsertTagRows(tags: List<TagEntity>)

    @Transaction
    suspend fun deleteTagRowsById(ids: List<String>) {
        ids.chunked(SQL_CHUNK).forEach { deleteTagRowsByIdChunk(it) }
    }

    @Query("DELETE FROM tags WHERE id IN (:ids)")
    suspend fun deleteTagRowsByIdChunk(ids: List<String>)

    @Query("DELETE FROM tags WHERE name_key = :nameKey")
    suspend fun deleteTagRowByKey(nameKey: String)

    @Query("SELECT * FROM tags")
    suspend fun allTagRows(): List<TagEntity>

    // ---- Resync (A8.3) -----------------------------------------------------------------------

    @Query("UPDATE items SET resync_mark = 1")
    suspend fun markAllForResync()

    /**
     * Deletes items still marked after a full pull that have no pending ops; returns their ids
     * (so the caller can remove their files).
     */
    @Transaction
    suspend fun deleteStaleMarkedItems(): List<String> {
        val ids = staleMarkedIds()
        deleteItems(ids)
        return ids
    }

    @Query(
        """SELECT id FROM items WHERE resync_mark = 1
           AND NOT EXISTS (SELECT 1 FROM pending_ops p WHERE p.item_id = items.id)""",
    )
    suspend fun staleMarkedIds(): List<String>

    @Query("UPDATE items SET resync_mark = 0")
    suspend fun clearResyncMarks()

    // ---- Internals (public only because Room generates implementations) ----------------------

    @Upsert
    suspend fun upsertRaw(item: ItemEntity)

    @Query("SELECT fts_rowid FROM items WHERE id = :id")
    suspend fun ftsRowIdOf(id: String): Long?

    @Query("SELECT COALESCE(MAX(fts_rowid), 0) + 1 FROM items")
    suspend fun nextFtsRowId(): Long

    @Query("DELETE FROM item_tags WHERE item_id = :itemId")
    suspend fun deleteTagRows(itemId: String)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertTagRows(tags: List<ItemTagEntity>)

    @Query("DELETE FROM items WHERE id = :id")
    suspend fun deleteItemRow(id: String)

    @Query("UPDATE items SET title = :title WHERE id = :id")
    suspend fun updateTitle(id: String, title: String?)

    @Query("SELECT title, excerpt, site_name, tags FROM items_fts WHERE rowid = :rowId")
    suspend fun ftsMeta(rowId: Long): FtsMeta?

    @Query("SELECT body FROM items_fts WHERE rowid = :rowId")
    suspend fun ftsRowExists(rowId: Long): String?

    @Query("DELETE FROM items_fts WHERE rowid = :rowId")
    suspend fun deleteFtsRow(rowId: Long)

    @Query(
        """INSERT INTO items_fts(rowid, title, excerpt, site_name, tags, body)
           VALUES (:rowId, :title, :excerpt, :siteName, :tags, :body)""",
    )
    suspend fun insertFtsRow(rowId: Long, title: String, excerpt: String, siteName: String, tags: String, body: String)

    @Query("UPDATE items_fts SET body = :body WHERE rowid = :rowId")
    suspend fun updateFtsBody(rowId: Long, body: String)

    /** Tag rows for [names] as stored: trimmed, normalized, de-duplicated by key (first wins). */
    private fun cleanTagRows(itemId: String, names: List<String>): List<ItemTagEntity> =
        names.map { it.trim() }.filter { it.isNotEmpty() }
            .map { ItemTagEntity(itemId, tagKey(it), app.sroka.core.model.normalizeTagName(it)) }
            .distinctBy { it.nameKey }

    private suspend fun replaceTagRows(itemId: String, names: List<String>) {
        deleteTagRows(itemId)
        val rows = cleanTagRows(itemId, names)
        if (rows.isNotEmpty()) insertTagRows(rows)
    }

    private fun ItemEntity.indexedFieldsDiffer(other: ItemEntity) =
        title != other.title || excerpt != other.excerpt || siteName != other.siteName

    /** Rewrites the item's FTS row from current item + tags, keeping any stored body. */
    private suspend fun refreshFts(itemId: String) {
        val item = getItem(itemId) ?: return
        val want = FtsMeta(
            title = item.title.orEmpty(),
            excerpt = item.excerpt.orEmpty(),
            siteName = item.siteName.orEmpty(),
            tags = tagNames(itemId).joinToString(" "),
        )
        // Re-tokenizing a stored body is expensive: leave the row alone when nothing indexed changed.
        if (ftsMeta(item.ftsRowId) == want) return
        val body = ftsRowExists(item.ftsRowId).orEmpty()
        deleteFtsRow(item.ftsRowId)
        insertFtsRow(item.ftsRowId, want.title, want.excerpt, want.siteName, want.tags, body)
    }
}

/** The indexed metadata columns of an `items_fts` row (everything but `body`). */
data class FtsMeta(
    val title: String,
    val excerpt: String,
    @ColumnInfo(name = "site_name") val siteName: String,
    val tags: String,
)
