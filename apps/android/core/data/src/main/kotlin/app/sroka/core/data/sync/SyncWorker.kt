package app.sroka.core.data.sync

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import app.sroka.core.data.content.ContentStoreImpl
import app.sroka.core.datastore.SessionStore
import app.sroka.core.domain.SyncEvent
import app.sroka.core.model.SyncErrorKind
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject

/**
 * Runs [SyncEngine.sync] (DECISIONS A8). Background runs retry with backoff on network/server
 * errors and then schedule automatic downloads + eviction; a user fetch (input `user`) fails fast
 * and reports the failure as a [SyncEvent], its download step is chained by [WorkScheduler.enqueueFetch].
 */
@HiltWorker
class SyncWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val engine: SyncEngine,
    private val sessionStore: SessionStore,
    private val scheduler: WorkScheduler,
    private val contentStore: ContentStoreImpl,
    private val events: SyncEventBus,
) : CoroutineWorker(context, params) {

    private val user get() = inputData.getBoolean(SyncWork.KEY_USER, false)

    override suspend fun getForegroundInfo(): ForegroundInfo = SyncNotifications.syncing(applicationContext)

    override suspend fun doWork(): Result {
        val session = sessionStore.current()
        if (session == null || session.expired) {
            if (user && session != null) events.emit(SyncEvent.FetchFailed(SyncErrorKind.AUTH))
            // Nothing to do while signed out / expired; a user fetch must not run its download step.
            return if (user) Result.failure() else Result.success()
        }
        return when (val outcome = engine.sync()) {
            is SyncOutcome.Success -> {
                if (!user) scheduler.enqueueAutoDownload()
                contentStore.evict()
                Result.success()
            }
            is SyncOutcome.Failure -> when {
                user -> {
                    events.emit(SyncEvent.FetchFailed(outcome.kind))
                    Result.failure()
                }
                outcome.kind == SyncErrorKind.AUTH -> Result.failure()
                runAttemptCount < MAX_ATTEMPTS -> Result.retry()
                else -> Result.failure()
            }
        }
    }

    private companion object {
        const val MAX_ATTEMPTS = 5
    }
}
