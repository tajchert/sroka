package app.sroka.core.data.repository

import android.content.Context
import androidx.core.content.edit
import app.sroka.core.common.di.Dispatcher
import app.sroka.core.common.di.SrokaDispatchers
import app.sroka.core.data.content.ContentPaths
import app.sroka.core.data.sync.SyncControllerImpl
import app.sroka.core.data.sync.SyncEngine
import app.sroka.core.data.sync.WorkScheduler
import app.sroka.core.database.dao.MaintenanceDao
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Removes everything that belongs to the signed-in account: background work, database rows (items,
 * tags, FTS, pending ops, cursor) and downloaded files. Runs under the sync mutex so a running sync
 * cannot write rows back afterwards.
 */
@Singleton
internal class LocalDataWiper @Inject constructor(
    private val scheduler: WorkScheduler,
    private val syncController: SyncControllerImpl,
    private val engine: SyncEngine,
    private val maintenanceDao: MaintenanceDao,
    private val paths: ContentPaths,
    @Dispatcher(SrokaDispatchers.IO) private val io: CoroutineDispatcher,
) {
    suspend fun wipe() {
        scheduler.cancelAll()
        syncController.resetPeriodic()
        engine.exclusive {
            maintenanceDao.wipeAll()
            withContext(io) { paths.deleteAll() }
        }
    }
}

/**
 * Email of the account whose data is in the local database. Kept outside the encrypted session so
 * that it survives Keystore key loss: signing in as someone else must never show the previous
 * account's library.
 */
@Singleton
internal class AccountMarker @Inject constructor(@ApplicationContext context: Context) {
    private val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    var email: String?
        get() = prefs.getString(KEY_EMAIL, null)
        set(value) = prefs.edit { if (value == null) remove(KEY_EMAIL) else putString(KEY_EMAIL, value) }

    private companion object {
        const val FILE = "sroka_account"
        const val KEY_EMAIL = "email"
    }
}
