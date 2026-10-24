package app.sroka.core.database

import androidx.room3.Database
import androidx.room3.DaoReturnTypeConverters
import androidx.room3.RoomDatabase
import androidx.room3.useWriterConnection
import androidx.room3.paging.PagingSourceDaoReturnTypeConverter
import app.sroka.core.database.dao.ContentFileDao
import app.sroka.core.database.dao.ItemDao
import app.sroka.core.database.dao.MaintenanceDao
import app.sroka.core.database.dao.PendingOpDao
import app.sroka.core.database.dao.SyncStateDao
import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ItemEntity
import app.sroka.core.database.entity.ItemFtsEntity
import app.sroka.core.database.entity.ItemTagEntity
import app.sroka.core.database.entity.PendingOpEntity
import app.sroka.core.database.entity.SyncStateEntity
import app.sroka.core.database.entity.TagEntity

/**
 * Local source of truth (DECISIONS A4). Schemas are exported to `core/database/schemas/`.
 * Every schema change = version bump + explicit `Migration` + migration test; never destructive.
 * Combine DAO calls atomically with `withWriteTransaction { }` (androidx.room3).
 */
@Database(
    entities = [
        ItemEntity::class,
        ItemTagEntity::class,
        TagEntity::class,
        ItemFtsEntity::class,
        PendingOpEntity::class,
        SyncStateEntity::class,
        ContentFileEntity::class,
    ],
    version = 2,
    exportSchema = true,
)
@DaoReturnTypeConverters(PagingSourceDaoReturnTypeConverter::class)
abstract class SrokaDatabase : RoomDatabase() {
    abstract fun itemDao(): ItemDao
    abstract fun pendingOpDao(): PendingOpDao
    abstract fun syncStateDao(): SyncStateDao
    abstract fun contentFileDao(): ContentFileDao
    abstract fun maintenanceDao(): MaintenanceDao

    companion object {
        const val FILE_NAME = "sroka.db"
    }
}

/**
 * Reclaims free pages (DELETE never shrinks the file). Must run outside any transaction; a WAL
 * checkpoint first so the -wal file does not keep deleted text around.
 */
suspend fun SrokaDatabase.vacuum() {
    useWriterConnection { connection ->
        connection.usePrepared("PRAGMA wal_checkpoint(TRUNCATE)") { it.step() }
        connection.usePrepared("VACUUM") { it.step() }
    }
}
