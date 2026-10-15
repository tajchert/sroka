package app.sroka.core.data.sync

import app.sroka.core.common.di.ApplicationScope
import app.sroka.core.domain.SyncController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Fire-and-forget triggers (DECISIONS A8). [requestSync] is debounced by 2 s so a burst of local
 * writes produces one sync; the hourly periodic sync is (re)scheduled on first use.
 */
@Singleton
internal class SyncControllerImpl @Inject constructor(
    private val scheduler: WorkScheduler,
    @ApplicationScope private val scope: CoroutineScope,
) : SyncController {

    private val periodicScheduled = AtomicBoolean(false)
    private var pending: Job? = null

    override fun requestSync() {
        ensurePeriodic()
        synchronized(this) {
            pending?.cancel()
            pending = scope.launch {
                delay(DEBOUNCE_MS)
                scheduler.enqueueSync()
            }
        }
    }

    override fun fetchNewArticles() {
        ensurePeriodic()
        synchronized(this) {
            pending?.cancel()
            pending = null
        }
        scheduler.enqueueFetch()
    }

    override fun downloadItemNow(itemId: String) {
        scheduler.enqueueItemDownload(itemId)
    }

    /** After sign-out the periodic work is cancelled; the next trigger schedules it again. */
    fun resetPeriodic() = periodicScheduled.set(false)

    private fun ensurePeriodic() {
        if (periodicScheduled.compareAndSet(false, true)) scheduler.schedulePeriodicSync()
    }

    private companion object {
        const val DEBOUNCE_MS = 2_000L
    }
}
