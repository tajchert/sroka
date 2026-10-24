package app.sroka.core.data.transfer

import app.sroka.core.datastore.SessionStore
import app.sroka.core.model.ImportJob
import app.sroka.core.model.JobStatus
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SrokaApi
import kotlinx.coroutines.delay
import javax.inject.Inject
import javax.inject.Singleton

/** Result of one `GET /v1/imports/:id` poll. */
sealed interface PollOutcome {
    data class Updated(val job: ImportJob) : PollOutcome

    /** Connectivity or 5xx: try again later. */
    data object Transient : PollOutcome

    /** Signed out (401) or no stored job to poll: stop polling. */
    data object Stop : PollOutcome
}

/** The polling logic of [ImportProgressWorker], free of WorkManager so it can be unit tested. */
@Singleton
class ImportTracker @Inject internal constructor(
    private val api: SrokaApi,
    private val store: ImportJobStore,
    private val sessionStore: SessionStore,
) {
    suspend fun refresh(jobId: String): PollOutcome {
        val known = store.current()?.takeIf { it.id == jobId } ?: return PollOutcome.Stop
        return when (val r = api.getImport(jobId)) {
            is ApiResult.Success -> {
                val job = r.value.toImportJob(known.format)
                store.update(job)
                PollOutcome.Updated(job)
            }
            is ApiResult.NetworkError -> PollOutcome.Transient
            is ApiResult.HttpError -> when (r.status) {
                401 -> {
                    sessionStore.markExpired()
                    PollOutcome.Stop
                }
                404 -> {
                    // The server no longer knows the job: record a terminal state so the UI is never stuck.
                    val lost = known.copy(status = JobStatus.FAILED, error = ERROR_LOST)
                    store.update(lost)
                    PollOutcome.Updated(lost)
                }
                else -> PollOutcome.Transient
            }
        }
    }

    companion object {
        /** Error code stored when the server reports the job as gone (404). */
        const val ERROR_LOST = "lost"
    }
}

/** How a [pollUntilFinished] loop ended. */
enum class PollEnd { FINISHED, STOPPED, TOO_MANY_ERRORS }

/**
 * Polls [refresh] every [intervalMs] until the job is done/failed, [refresh] says stop, or [maxConsecutiveErrors]
 * transient failures happen in a row. [onJob] is called for every fetched job (to update the notification).
 */
suspend fun pollUntilFinished(
    intervalMs: Long,
    maxConsecutiveErrors: Int,
    refresh: suspend () -> PollOutcome,
    onJob: suspend (ImportJob) -> Unit,
): PollEnd {
    var errors = 0
    while (true) {
        when (val o = refresh()) {
            is PollOutcome.Updated -> {
                errors = 0
                onJob(o.job)
                if (o.job.status.isFinished) return PollEnd.FINISHED
            }
            PollOutcome.Transient -> if (++errors >= maxConsecutiveErrors) return PollEnd.TOO_MANY_ERRORS
            PollOutcome.Stop -> return PollEnd.STOPPED
        }
        delay(intervalMs)
    }
}
