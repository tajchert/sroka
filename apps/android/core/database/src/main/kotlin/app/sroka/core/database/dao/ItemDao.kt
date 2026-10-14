package app.sroka.core.database.dao

import androidx.paging.PagingSource
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
        val status = if (tagKey == null) {
            when (query.tab) {
                LibraryTab.MY_LIST -> ItemStatus.UNREAD.name
                LibraryTab.ARCHIVE -> ItemStatus.ARCHIVED.name
                LibraryTab.FAVORITES -> null
            }
        } else {
            null
        }
        val favorites = if (tagKey == null && query.tab == LibraryTab.FAVORITES) 1 else 0
        val match = query.search?.let { FtsQuery.build(it) }
        return if (match == null) {
            when (query.sort) {
                SortOrder.NEWEST -> listNewest(tagKey, status, favorites)
                SortOrder.OLDEST -> listOldest(tagKey, status, favorites)
                SortOrder.SHORTEST -> listShortest(tagKey, status, favorites)
                SortOrder.LONGEST -> listLongest(tagKey, status, favorites)
            }
        } else {
            when (query.sort) {
                SortOrder.NEWEST -> searchNewest(match, tagKey, status, favorites)
                SortOrder.OLDEST -> searchOldest(match, tagKey, status, favorites)
                SortOrder.SHORTEST -> searchShortest(match, tagKey, status, favorites)
                SortOrder.LONGEST -> searchLongest(match, tagKey, status, favorites)
            }
        }
    }

    @Query("$ROW_COLUMNS $LIST_FROM WHERE $FILTER $ORDER_NEWEST")
    fun listNewest(tagKey: String?, status: String?, favoritesOnly: Int): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM WHERE $FILTER $ORDER_OLDEST")
    fun listOldest(tagKey: String?, status: String?, favoritesOnly: Int): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM WHERE $FILTER $ORDER_SHORTEST")
    fun listShortest(tagKey: String?, status: String?, favoritesOnly: Int): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $LIST_FROM WHERE $FILTER $ORDER_LONGEST")
    fun listLongest(tagKey: String?, status: String?, favoritesOnly: Int): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE items_fts MATCH :match AND $FILTER $ORDER_NEWEST")
    fun searchNewest(match: String, tagKey: String?, status: String?, favoritesOnly: Int): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE items_fts MATCH :match AND $FILTER $ORDER_OLDEST")
    fun searchOldest(match: String, tagKey: String?, status: String?, favoritesOnly: Int): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE items_fts MATCH :match AND $FILTER $ORDER_SHORTEST")
    fun searchShortest(match: String, tagKey: String?, status: String?, favoritesOnly: Int): PagingSource<Int, ItemSummaryRow>

    @Query("$ROW_COLUMNS $SEARCH_FROM WHERE items_fts MATCH :match AND $FILTER $ORDER_LONGEST")
    fun searchLongest(match: String, tagKey: String?, status: String?, favoritesOnly: Int): PagingSource<Int, ItemSummaryRow>

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
        """SELECT MIN(it.name) FROM item_tags it JOIN items i ON i.id = it.item_id
           GROUP BY it.name_key ORDER BY MAX(i.saved_at) DESC, it.name_key LIMIT :limit""",
    )
    fun observeRecentTags(limit: Int): Flow<List<String>>

    @Query("SELECT name FROM item_tags WHERE item_id = :itemId ORDER BY name_key")
    suspend fun tagNames(itemId: String): List<String>

    @Query("SELECT item_id FROM item_tags WHERE name_key = :nameKey")
    suspend fun itemIdsWithTag(nameKey: String): List<String>

    @Query("SELECT id FROM items WHERE id IN (:ids)")
    suspend fun existingIds(ids: List<String>): List<String>

    // ---- Writes ------------------------------------------------------------------------------

    /**
     * Inserts or updates [item], preserving its `fts_rowid` and child rows (tags, content_files),
     * and refreshes its FTS row (title/excerpt/site/tags; downloaded `body` is kept).
     */
    @Transaction
    suspend fun upsertItem(item: ItemEntity) {
        val rowId = ftsRowIdOf(item.id) ?: nextFtsRowId()
        upsertRaw(item.copy(ftsRowId = rowId))
        refreshFts(item.id)
    }

    /** [upsertItem] plus a full replacement of the item's tags, with one FTS write. */
    @Transaction
    suspend fun upsertItemWithTags(item: ItemEntity, tagNames: List<String>) {
        val rowId = ftsRowIdOf(item.id) ?: nextFtsRowId()
        upsertRaw(item.copy(ftsRowId = rowId))
        replaceTagRows(item.id, tagNames)
        refreshFts(item.id)
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

    @Query("DELETE FROM tags WHERE id IN (:ids)")
    suspend fun deleteTagRowsById(ids: List<String>)

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

    private suspend fun replaceTagRows(itemId: String, names: List<String>) {
        deleteTagRows(itemId)
        val rows = names.map { it.trim() }.filter { it.isNotEmpty() }
            .map { ItemTagEntity(itemId, tagKey(it), app.sroka.core.model.normalizeTagName(it)) }
            .distinctBy { it.nameKey }
        if (rows.isNotEmpty()) insertTagRows(rows)
    }

    /** Rewrites the item's FTS row from current item + tags, keeping any stored body. */
    private suspend fun refreshFts(itemId: String) {
        val item = getItem(itemId) ?: return
        val body = ftsRowExists(item.ftsRowId).orEmpty()
        deleteFtsRow(item.ftsRowId)
        insertFtsRow(
            rowId = item.ftsRowId,
            title = item.title.orEmpty(),
            excerpt = item.excerpt.orEmpty(),
            siteName = item.siteName.orEmpty(),
            tags = tagNames(itemId).joinToString(" "),
            body = body,
        )
    }
}
