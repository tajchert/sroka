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

    @Query("SELECT * FROM pending_ops WHERE item_id IN (:itemIds) ORDER BY local_seq")
    suspend fun forItems(itemIds: List<String>): List<PendingOpEntity>

    @Query("SELECT * FROM pending_ops WHERE item_id = :itemId ORDER BY local_seq")
    suspend fun forItem(itemId: String): List<PendingOpEntity>

    @Query("DELETE FROM pending_ops WHERE op_id IN (:opIds)")
    suspend fun deleteByOpIds(opIds: List<String>)

    @Query("DELETE FROM pending_ops WHERE item_id = :itemId")
    suspend fun deleteForItem(itemId: String)

    @Query("UPDATE pending_ops SET attempts = attempts + 1, last_error = :error WHERE op_id IN (:opIds)")
    suspend fun markAttempted(opIds: List<String>, error: String?)

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

    @Query("DELETE FROM pending_ops")
    suspend fun deleteAll()
}
