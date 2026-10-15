package app.sroka.core.database.dao

import androidx.room3.Dao
import androidx.room3.Query
import androidx.room3.Transaction
import androidx.room3.Upsert
import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.EligibleDownloadRow
import kotlinx.coroutines.flow.Flow

/** Downloaded-package bookkeeping and download selection (A9). */
@Dao
interface ContentFileDao {

    @Upsert
    suspend fun upsert(file: ContentFileEntity)

    @Query("SELECT * FROM content_files WHERE item_id = :itemId")
    suspend fun get(itemId: String): ContentFileEntity?

    @Query("SELECT * FROM content_files WHERE item_id = :itemId")
    fun observe(itemId: String): Flow<ContentFileEntity?>

    @Query("SELECT * FROM content_files")
    suspend fun all(): List<ContentFileEntity>

    @Query("DELETE FROM content_files WHERE item_id = :itemId")
    suspend fun delete(itemId: String)

    @Transaction
    suspend fun delete(itemIds: List<String>) {
        itemIds.chunked(SQL_CHUNK).forEach { deleteChunk(it) }
    }

    @Query("DELETE FROM content_files WHERE item_id IN (:itemIds)")
    suspend fun deleteChunk(itemIds: List<String>)

    @Query("DELETE FROM content_files")
    suspend fun deleteAll()

    /**
     * Items to download, newest saved first: live, with content, unread or favorite, and whose
     * file row is missing, stale (other content id), QUEUED, or FAILED with fewer than
     * [maxAttempts] attempts. DOWNLOADING rows are excluded (see [resetDownloading]).
     */
    @Query(
        """SELECT i.id AS item_id, i.content_id AS content_id
           FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id
           WHERE i.content_id IS NOT NULL AND (i.status = 'UNREAD' OR i.is_favorite = 1)
             AND (cf.item_id IS NULL OR cf.content_id != i.content_id OR cf.state = 'QUEUED'
                  OR (cf.state = 'FAILED' AND cf.attempts < :maxAttempts))
           ORDER BY i.saved_at DESC, i.id DESC LIMIT :limit""",
    )
    suspend fun eligibleForDownload(maxAttempts: Int = 5, limit: Int = -1): List<EligibleDownloadRow>

    /**
     * Current packages that still lack their thumbnail (a failed fetch is otherwise never retried
     * because the row is DOWNLOADED); capped by `thumb_attempts`.
     */
    @Query(
        """SELECT i.id AS item_id, i.content_id AS content_id
           FROM items i JOIN content_files cf ON cf.item_id = i.id
           WHERE cf.state = 'DOWNLOADED' AND cf.content_id = i.content_id AND cf.thumb_path IS NULL
             AND i.lead_image_key IS NOT NULL AND cf.thumb_attempts < :maxAttempts
           ORDER BY i.saved_at DESC, i.id DESC""",
    )
    suspend fun thumbsToRetry(maxAttempts: Int = 3): List<EligibleDownloadRow>

    @Query(
        """SELECT COUNT(*) FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id
           WHERE i.content_id IS NOT NULL AND (i.status = 'UNREAD' OR i.is_favorite = 1)
             AND (cf.item_id IS NULL OR cf.content_id != i.content_id OR cf.state = 'QUEUED'
                  OR (cf.state = 'FAILED' AND cf.attempts < :maxAttempts))""",
    )
    fun observeEligibleCount(maxAttempts: Int = 5): Flow<Int>

    /** Items with a current (non-stale) downloaded package. */
    @Query(
        """SELECT COUNT(*) FROM content_files cf JOIN items i ON i.id = cf.item_id
           WHERE cf.state = 'DOWNLOADED' AND cf.content_id = i.content_id""",
    )
    fun observeDownloadedCount(): Flow<Int>

    /** Crash recovery: a process that died leaves DOWNLOADING rows; re-queue them (once per process). */
    @Query("UPDATE content_files SET state = 'QUEUED' WHERE state = 'DOWNLOADING'")
    suspend fun resetDownloading()

    @Query("SELECT COALESCE(SUM(bytes), 0) FROM content_files WHERE state = 'DOWNLOADED'")
    suspend fun totalBytes(): Long

    @Query("SELECT COALESCE(SUM(bytes), 0) FROM content_files WHERE state = 'DOWNLOADED'")
    fun observeTotalBytes(): Flow<Long>

    @Query("SELECT thumb_path FROM content_files WHERE thumb_path IS NOT NULL")
    suspend fun thumbPaths(): List<String>

    /** Downloaded packages of archived, non-favorite items archived before [archivedBefore] (A9 eviction). */
    @Query(
        """SELECT cf.item_id FROM content_files cf JOIN items i ON i.id = cf.item_id
           WHERE cf.state = 'DOWNLOADED' AND i.status = 'ARCHIVED' AND i.is_favorite = 0
             AND i.archived_at IS NOT NULL AND i.archived_at < :archivedBefore
           LIMIT :limit""",
    )
    suspend fun evictionCandidates(archivedBefore: Long, limit: Int = 500): List<String>
}
