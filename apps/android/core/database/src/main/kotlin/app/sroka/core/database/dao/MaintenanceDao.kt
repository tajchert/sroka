package app.sroka.core.database.dao

import androidx.room3.Dao
import androidx.room3.Query
import androidx.room3.Transaction

@Dao
interface MaintenanceDao {

    /** Sign-out: removes every row of every table, including the FTS index. */
    @Transaction
    suspend fun wipeAll() {
        deleteFts()
        deleteContentFiles()
        deleteItemTags()
        deleteTags()
        deleteItems()
        deletePendingOps()
        deleteSyncState()
    }

    @Query("DELETE FROM items_fts") suspend fun deleteFts()
    @Query("DELETE FROM content_files") suspend fun deleteContentFiles()
    @Query("DELETE FROM item_tags") suspend fun deleteItemTags()
    @Query("DELETE FROM tags") suspend fun deleteTags()
    @Query("DELETE FROM items") suspend fun deleteItems()
    @Query("DELETE FROM pending_ops") suspend fun deletePendingOps()
    @Query("DELETE FROM sync_state") suspend fun deleteSyncState()
}
