package app.sroka.core.data.sync

import android.content.Context
import androidx.work.WorkInfo
import androidx.work.WorkManager
import app.sroka.core.database.dao.ContentFileDao
import app.sroka.core.database.dao.PendingOpDao
import app.sroka.core.database.dao.SyncStateDao
import app.sroka.core.database.entity.SyncStateEntity
import app.sroka.core.datastore.SessionStore
import app.sroka.core.domain.SyncEvent
import app.sroka.core.domain.SyncStatusRepository
import app.sroka.core.model.SyncErrorKind
import app.sroka.core.model.SyncPhase
import app.sroka.core.model.SyncStatus
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

/** [SyncStatus] from WorkManager state + Room counts + connectivity + session (DECISIONS A9/A11). */
@Singleton
internal class SyncStatusRepositoryImpl @Inject constructor(
    @ApplicationContext private val context: Context,
    private val pendingOpDao: PendingOpDao,
    private val contentFileDao: ContentFileDao,
    private val syncStateDao: SyncStateDao,
    private val sessionStore: SessionStore,
    private val networkMonitor: NetworkMonitor,
    private val eventBus: SyncEventBus,
) : SyncStatusRepository {

    private val workManager: WorkManager get() = WorkManager.getInstance(context)

    override val status: Flow<SyncStatus> by lazy {
        val work = combine(
            workManager.getWorkInfosByTagFlow(SyncWork.TAG_SYNC),
            workManager.getWorkInfosByTagFlow(SyncWork.TAG_DOWNLOAD),
        ) { sync, download -> WorkSnapshot.of(sync, download) }
        val counts = combine(
            pendingOpDao.observeCount(),
            contentFileDao.observeDownloadedCount(),
            contentFileDao.observeEligibleCount(),
            syncStateDao.observe(),
        ) { pending, downloaded, available, state -> Counts(pending, downloaded, available, state ?: SyncStateEntity()) }
        val expired = sessionStore.session.map { it?.expired == true }
        combine(work, counts, networkMonitor.isOnline, expired) { w, c, online, isExpired ->
            SyncStatus(
                phase = phaseOf(w, c.state, online, isExpired),
                pendingOps = c.pending,
                downloadedCount = c.downloaded,
                availableCount = c.available,
                lastSyncAt = c.state.lastSuccessAt,
            )
        }.distinctUntilChanged()
    }

    override val events: Flow<SyncEvent> get() = eventBus.events

    private data class Counts(val pending: Int, val downloaded: Int, val available: Int, val state: SyncStateEntity)

    internal data class WorkSnapshot(val syncing: Boolean, val downloading: SyncPhase.Downloading?) {
        companion object {
            fun of(sync: List<WorkInfo>, download: List<WorkInfo>): WorkSnapshot {
                val running = download.firstOrNull { it.state == WorkInfo.State.RUNNING }
                return WorkSnapshot(
                    syncing = sync.any { it.state == WorkInfo.State.RUNNING },
                    downloading = running?.progress?.let {
                        SyncPhase.Downloading(
                            done = it.getInt(SyncWork.KEY_DONE, 0),
                            total = it.getInt(SyncWork.KEY_TOTAL, 0),
                            currentTitle = it.getString(SyncWork.KEY_TITLE),
                        )
                    },
                )
            }
        }
    }

    internal companion object {
        fun phaseOf(work: WorkSnapshot, state: SyncStateEntity, online: Boolean, expired: Boolean): SyncPhase = when {
            expired -> SyncPhase.Error(SyncErrorKind.AUTH)
            work.syncing -> SyncPhase.Syncing
            work.downloading != null -> work.downloading
            !online -> SyncPhase.Offline
            else -> state.lastError
                ?.let { runCatching { SyncErrorKind.valueOf(it) }.getOrNull() }
                // A network error while the device reports connectivity is transient; do not alarm.
                ?.takeIf { it != SyncErrorKind.NETWORK }
                ?.let { SyncPhase.Error(it) }
                ?: SyncPhase.Idle
        }
    }
}
