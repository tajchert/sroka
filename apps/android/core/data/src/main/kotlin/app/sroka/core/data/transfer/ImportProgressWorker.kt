package app.sroka.core.data.transfer

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import app.sroka.core.data.sync.SyncWork
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Polls `GET /v1/imports/:id` every ~3 s while the job is queued/running, mirrors it into [ImportJobStore] and a
 * progress notification (foreground `dataSync`), then posts the final result notification.
 */
@HiltWorker
class ImportProgressWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val tracker: ImportTracker,
    private val store: ImportJobStore,
) : CoroutineWorker(context, params) {

    override suspend fun getForegroundInfo(): ForegroundInfo =
        ImportNotifications.foregroundInfo(applicationContext, store.current())

    override suspend fun doWork(): Result {
        val jobId = inputData.getString(KEY_JOB_ID) ?: return Result.failure()
        foreground()
        val end = pollUntilFinished(
            intervalMs = POLL_INTERVAL_MS,
            maxConsecutiveErrors = MAX_CONSECUTIVE_ERRORS,
            refresh = { tracker.refresh(jobId) },
            onJob = { job ->
                if (job.status.isFinished) {
                    ImportNotifications.cancelProgress(applicationContext)
                    ImportNotifications.showResult(applicationContext, job)
                } else {
                    ImportNotifications.updateProgress(applicationContext, job)
                }
            },
        )
        if (end != PollEnd.FINISHED) ImportNotifications.cancelProgress(applicationContext)
        return if (end == PollEnd.TOO_MANY_ERRORS && runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.success()
    }

    /** Best effort: Android 12+ may refuse a foreground start from the background; polling continues anyway. */
    private suspend fun foreground() {
        try {
            setForeground(getForegroundInfo())
        } catch (_: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException is an IllegalStateException.
        }
    }

    companion object {
        const val KEY_JOB_ID = "jobId"
        const val POLL_INTERVAL_MS = 3_000L
        private const val MAX_CONSECUTIVE_ERRORS = 40
        private const val MAX_ATTEMPTS = 5

        fun uniqueName(jobId: String) = "sroka-import-$jobId"
    }
}

/** Starts [ImportProgressWorker]; separate so the repository is testable without WorkManager. */
fun interface ImportScheduler {
    fun enqueue(jobId: String)
}

@Singleton
internal class WorkImportScheduler @Inject constructor(
    @ApplicationContext private val context: Context,
) : ImportScheduler {
    override fun enqueue(jobId: String) {
        val request = OneTimeWorkRequestBuilder<ImportProgressWorker>()
            .setInputData(workDataOf(ImportProgressWorker.KEY_JOB_ID to jobId))
            .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag(SyncWork.TAG_ALL)
            .build()
        WorkManager.getInstance(context)
            .enqueueUniqueWork(ImportProgressWorker.uniqueName(jobId), ExistingWorkPolicy.KEEP, request)
    }
}
