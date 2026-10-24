package app.sroka.core.data.upload

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import app.sroka.core.data.content.ContentPaths
import app.sroka.core.data.sync.WorkScheduler
import app.sroka.core.datastore.SessionStore
import app.sroka.core.model.PdfUploadError
import app.sroka.core.network.SrokaApi
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Uploads one copied PDF (`filesDir/pdf-uploads/{id}.pdf`). The file stays until success or a permanent
 * error; transient errors retry with exponential backoff up to [MAX_ATTEMPTS], then fail. On success the
 * temp copy is deleted and a sync is queued so the new item arrives through the normal pull.
 * Progress is published via `setProgress(sent, total)`; results via output data (see [PdfUploadWork]).
 */
@HiltWorker
class PdfUploadWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val api: SrokaApi,
    private val paths: ContentPaths,
    private val sessionStore: SessionStore,
    private val scheduler: WorkScheduler,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val id = inputData.getString(PdfUploadWork.KEY_ID) ?: return Result.failure(error(PdfUploadError.UNKNOWN))
        val name = inputData.getString(PdfUploadWork.KEY_NAME) ?: "document.pdf"
        if (!ContentPaths.isSafeId(id)) return Result.failure(error(PdfUploadError.UNKNOWN))
        val file = paths.pdfUploadFile(id)
        val session = sessionStore.current()
        // Signed out: the sign-out wipe cancels this work and deletes the files; just wait.
        if (session == null || session.expired) return retryOrGiveUp(file, PdfUploadError.AUTH)

        val outcome = coroutineScope {
            val progress = Channel<Pair<Long, Long>>(Channel.CONFLATED)
            val reporter: Job = launch {
                for ((sent, total) in progress) {
                    setProgress(workDataOf(PdfUploadWork.KEY_SENT to sent, PdfUploadWork.KEY_TOTAL to total))
                    delay(PROGRESS_INTERVAL_MS)
                }
            }
            try {
                PdfUploadProcessor(api).upload(file, name, SOURCE) { sent, total -> progress.trySend(sent to total) }
            } catch (e: CancellationException) {
                throw e
            } finally {
                reporter.cancel()
            }
        }
        return when (outcome) {
            is UploadOutcome.Uploaded -> {
                file.delete()
                scheduler.enqueueSync()
                Result.success(workDataOf(PdfUploadWork.KEY_ITEM_ID to outcome.itemId, PdfUploadWork.KEY_DUPLICATE to outcome.duplicate))
            }
            is UploadOutcome.Permanent -> {
                file.delete()
                Result.failure(error(outcome.error))
            }
            is UploadOutcome.Transient -> {
                if (outcome.error == PdfUploadError.AUTH) sessionStore.markExpired()
                retryOrGiveUp(file, outcome.error)
            }
        }
    }

    private fun retryOrGiveUp(file: java.io.File, error: PdfUploadError): Result =
        if (runAttemptCount + 1 >= MAX_ATTEMPTS) {
            file.delete()
            Result.failure(error(error))
        } else {
            Result.retry()
        }

    private fun error(e: PdfUploadError) = workDataOf(PdfUploadWork.KEY_ERROR to e.name)

    companion object {
        const val MAX_ATTEMPTS = 15
        private const val PROGRESS_INTERVAL_MS = 300L
        private const val SOURCE = "share"
    }
}
