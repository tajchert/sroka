package app.sroka.core.database.dao

import androidx.room3.Dao
import androidx.room3.Insert
import androidx.room3.OnConflictStrategy
import androidx.room3.Query
import androidx.room3.Transaction
import app.sroka.core.database.entity.PendingOpEntity
import kotlinx.coroutines.flow.Flow

/** Wire op types whose older un-sent ops of the same item are superseded (A7). */
val COALESCING_OP_TYPES: Set<String> = setOf(
    "item.setProgress",
    "item.setStatus",
    "item.setFavorite",
    "item.setTitle",
)

/** Stay below SQLITE_MAX_VARIABLE_NUMBER = 999 (Android API 26-30) for server/queue-sized IN lists. */
internal const val SQL_CHUNK = 900

@Dao
interface PendingOpDao {

    /**
     * Appends [op]; for [COALESCING_OP_TYPES] first removes older un-sent ops with the same
     * (item_id, type). Returns the new `local_seq`. Never coalesces add/tag/delete/tag-ops.
     */
    @Transaction
    suspend fun enqueue(op: PendingOpEntity): Long {
        if (op.itemId != null && op.type in COALESCING_OP_TYPES) deleteByItemAndType(op.itemId, op.type)
        return insert(op.copy(localSeq = 0))
    }

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(op: PendingOpEntity): Long

    @Query("DELETE FROM pending_ops WHERE item_id = :itemId AND type = :type")
    suspend fun deleteByItemAndType(itemId: String, type: String)

    /** Oldest-first batch for push. */
    @Query("SELECT * FROM pending_ops ORDER BY local_seq LIMIT :limit")
    suspend fun batch(limit: Int): List<PendingOpEntity>

    /** Queued ops of [itemIds] in `local_seq` order (chunked below SQLite's variable limit). */
    @Transaction
    suspend fun forItems(itemIds: List<String>): List<PendingOpEntity> =
        itemIds.chunked(SQL_CHUNK).flatMap { forItemsChunk(it) }.sortedBy { it.localSeq }

    @Query("SELECT * FROM pending_ops WHERE item_id IN (:itemIds) ORDER BY local_seq")
    suspend fun forItemsChunk(itemIds: List<String>): List<PendingOpEntity>

    /** Ops of [itemIds] plus every tag-level op (`item_id IS NULL`), in `local_seq` order. */
    @Query("SELECT * FROM pending_ops WHERE item_id IN (:itemIds) OR item_id IS NULL ORDER BY local_seq")
    suspend fun forItemsOrGlobal(itemIds: List<String>): List<PendingOpEntity>

    /** Tag-level ops (`tag.rename` / `tag.delete`). */
    @Query("SELECT * FROM pending_ops WHERE item_id IS NULL ORDER BY local_seq")
    suspend fun globalOps(): List<PendingOpEntity>

    @Query("SELECT * FROM pending_ops WHERE item_id = :itemId ORDER BY local_seq")
    suspend fun forItem(itemId: String): List<PendingOpEntity>

    @Transaction
    suspend fun deleteByOpIds(opIds: List<String>) {
        opIds.chunked(SQL_CHUNK).forEach { deleteByOpIdsChunk(it) }
    }

    @Query("DELETE FROM pending_ops WHERE op_id IN (:opIds)")
    suspend fun deleteByOpIdsChunk(opIds: List<String>)

    @Query("DELETE FROM pending_ops WHERE item_id = :itemId")
    suspend fun deleteForItem(itemId: String)

    @Transaction
    suspend fun markAttempted(opIds: List<String>, error: String?) {
        opIds.chunked(SQL_CHUNK).forEach { markAttemptedChunk(it, error) }
    }

    @Query("UPDATE pending_ops SET attempts = attempts + 1, last_error = :error WHERE op_id IN (:opIds)")
    suspend fun markAttemptedChunk(opIds: List<String>, error: String?)

    @Query("SELECT COUNT(*) FROM pending_ops")
    fun observeCount(): Flow<Int>

    @Query("SELECT COUNT(*) FROM pending_ops")
    suspend fun count(): Int

    /**
     * Alias handling (A8.1): point queued ops (row column and the compact wire JSON
     * `"itemId":"..."` in the payload) from [fromId] to [toId].
     */
    @Transaction
    suspend fun reassignItem(fromId: String, toId: String) {
        rewriteItemId(fromId, toId)
    }

    @Query(
        """UPDATE pending_ops SET item_id = :toId,
           payload = replace(payload, '"itemId":"' || :fromId || '"', '"itemId":"' || :toId || '"')
           WHERE item_id = :fromId""",
    )
    suspend fun rewriteItemId(fromId: String, toId: String)

    /** Gives a queued op a new id (the server already acknowledged the old one); payload follows. */
    @Query(
        """UPDATE pending_ops SET op_id = :newId,
           payload = replace(payload, '"opId":"' || :oldId || '"', '"opId":"' || :newId || '"')
           WHERE op_id = :oldId""",
    )
    suspend fun rewriteOpId(oldId: String, newId: String)

    @Query("DELETE FROM pending_ops")
    suspend fun deleteAll()
}
