package app.sroka.core.data.sync

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import app.sroka.core.data.content.ContentStoreImpl
import app.sroka.core.data.content.DownloadOutcome
import app.sroka.core.database.dao.ContentFileDao
import app.sroka.core.database.dao.ItemDao
import app.sroka.core.datastore.SessionStore
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.domain.SyncEvent
import app.sroka.core.model.SyncErrorKind
import app.sroka.core.model.displayDomain
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit

/**
 * Downloads article packages (DECISIONS A9): either one item (input `itemId`) or every eligible
 * item, newest first, 3 in parallel, as a foreground `dataSync` job with a progress notification and
 * `setProgress(done, total, title)`. A user fetch reports [SyncEvent.FetchCompleted] at the end.
 */
@HiltWorker
class ContentDownloadWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val contentStore: ContentStoreImpl,
    private val contentFileDao: ContentFileDao,
    private val itemDao: ItemDao,
    private val sessionStore: SessionStore,
    private val events: SyncEventBus,
) : CoroutineWorker(context, params) {

    private val user get() = inputData.getBoolean(SyncWork.KEY_USER, false)

    override suspend fun getForegroundInfo(): ForegroundInfo = SyncNotifications.downloading(applicationContext, 0, 0)

    override suspend fun doWork(): Result {
        val session = sessionStore.current()
        if (session == null || session.expired) {
            if (user && session != null) events.emit(SyncEvent.FetchFailed(SyncErrorKind.AUTH))
            return Result.success()
        }
        inputData.getString(SyncWork.KEY_ITEM_ID)?.let { return downloadOne(it) }
        return downloadAll()
    }

    private suspend fun downloadOne(itemId: String): Result =
        when (val r = contentStore.download(itemId)) {
            is DownloadOutcome.Failed -> if (r.reason == RemoteFailure.NETWORK && runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.success()
            else -> Result.success()
        }

    private suspend fun downloadAll(): Result {
        // Once per process (not per run): a second worker must not reset rows the first is downloading.
        contentStore.recoverInterrupted()
        val clearGen = contentStore.clearGeneration()
        val eligible = (
            contentFileDao.eligibleForDownload() +
                contentFileDao.thumbsToRetry(ContentStoreImpl.THUMB_MAX_ATTEMPTS)
            ).distinctBy { it.itemId }
        val total = eligible.size
        if (total == 0) return finish(downloaded = 0, failure = null)
        foreground(0, total)

        val lock = Mutex()
        var done = 0
        var downloaded = 0
        var failure: SyncErrorKind? = null
        var storageFull = false
        val permits = Semaphore(PARALLEL)
        coroutineScope {
            eligible.map { row ->
                async {
                    permits.withPermit {
                        if (lock.withLock { failure != null || storageFull }) return@withPermit
                        // "Remove downloads" ran meanwhile: do not re-fetch what the user cleared.
                        if (contentStore.clearGeneration() != clearGen) return@withPermit
                        val result = contentStore.download(row.itemId)
                        val title = itemDao.getItem(row.itemId)?.let { it.title ?: displayDomain(it.url) }
                        lock.withLock {
                            done++
                            when (result) {
                                // Only packages this run fetched count (not ones another run already had).
                                DownloadOutcome.Downloaded -> downloaded++
                                DownloadOutcome.AlreadyCurrent, DownloadOutcome.NotReady -> Unit
                                // Out of space: stop the batch, do not retry, tell the user.
                                DownloadOutcome.StorageFull -> storageFull = true
                                is DownloadOutcome.Failed -> when (result.reason) {
                                    // No point hammering the rest of the queue.
                                    RemoteFailure.NETWORK -> failure = SyncErrorKind.NETWORK
                                    RemoteFailure.UNAUTHORIZED -> failure = SyncErrorKind.AUTH
                                    else -> Unit
                                }
                            }
                            setProgress(workDataOf(SyncWork.KEY_DONE to done, SyncWork.KEY_TOTAL to total, SyncWork.KEY_TITLE to title))
                            foreground(done, total)
                        }
                    }
                }
            }.awaitAll()
        }
        return finish(downloaded, if (storageFull) SyncErrorKind.STORAGE else failure)
    }

    private fun finish(downloaded: Int, failure: SyncErrorKind?): Result {
        if (user) {
            events.emit(if (failure == null) SyncEvent.FetchCompleted(downloaded) else SyncEvent.FetchFailed(failure))
        }
        val output = workDataOf(SyncWork.KEY_DOWNLOADED to downloaded)
        return if (failure == SyncErrorKind.NETWORK && !user && runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.success(output)
    }

    /** Foreground is best effort: Android 12+ may refuse it from the background; downloads continue anyway. */
    private suspend fun foreground(done: Int, total: Int) {
        try {
            setForeground(SyncNotifications.downloading(applicationContext, done, total))
        } catch (_: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException is an IllegalStateException.
        }
    }

    private companion object {
        const val PARALLEL = 3
        const val MAX_ATTEMPTS = 5
    }
}
