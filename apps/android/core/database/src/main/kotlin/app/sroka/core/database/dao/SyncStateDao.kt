package app.sroka.core.database.dao

import androidx.room3.Dao
import androidx.room3.Query
import androidx.room3.Transaction
import androidx.room3.Upsert
import app.sroka.core.database.entity.SyncStateEntity
import kotlinx.coroutines.flow.Flow

/** The single `sync_state` row (id = 1); absent row reads as defaults. */
@Dao
interface SyncStateDao {

    @Query("SELECT * FROM sync_state WHERE id = 1")
    suspend fun find(): SyncStateEntity?

    @Query("SELECT * FROM sync_state WHERE id = 1")
    fun observe(): Flow<SyncStateEntity?>

    @Upsert
    suspend fun set(state: SyncStateEntity)

    suspend fun get(): SyncStateEntity = find() ?: SyncStateEntity()

    @Transaction
    suspend fun update(transform: (SyncStateEntity) -> SyncStateEntity) {
        set(transform(get()).copy(id = 1))
    }

    @Query("DELETE FROM sync_state")
    suspend fun deleteAll()
}
