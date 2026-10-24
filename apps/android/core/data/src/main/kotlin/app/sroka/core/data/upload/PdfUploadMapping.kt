package app.sroka.core.data.upload

import androidx.work.WorkInfo
import app.sroka.core.model.PdfUpload
import app.sroka.core.model.PdfUploadError
import app.sroka.core.model.PdfUploadState

/**
 * WorkInfo of a PDF upload job -> (enqueue time, [PdfUpload]); null for cancelled work or work without
 * our metadata tags. ENQUEUED/BLOCKED (including waiting for a retry) = Queued.
 */
internal fun pdfUploadOf(info: WorkInfo): Pair<Long, PdfUpload>? {
    fun tag(prefix: String) = info.tags.firstOrNull { it.startsWith(prefix) }?.removePrefix(prefix)
    val id = tag(PdfUploadWork.TAG_ID) ?: return null
    val at = tag(PdfUploadWork.TAG_AT)?.toLongOrNull() ?: 0L
    val state = when (info.state) {
        WorkInfo.State.ENQUEUED, WorkInfo.State.BLOCKED -> PdfUploadState.Queued
        WorkInfo.State.RUNNING -> {
            val sent = info.progress.getLong(PdfUploadWork.KEY_SENT, 0)
            val total = info.progress.getLong(PdfUploadWork.KEY_TOTAL, 0)
            PdfUploadState.Uploading(if (total > 0) (sent.toFloat() / total).coerceIn(0f, 1f) else 0f)
        }
        WorkInfo.State.SUCCEEDED -> PdfUploadState.Done(
            itemId = info.outputData.getString(PdfUploadWork.KEY_ITEM_ID),
            duplicate = info.outputData.getBoolean(PdfUploadWork.KEY_DUPLICATE, false),
        )
        WorkInfo.State.FAILED -> PdfUploadState.Failed(
            info.outputData.getString(PdfUploadWork.KEY_ERROR)
                ?.let { name -> PdfUploadError.entries.firstOrNull { it.name == name } }
                ?: PdfUploadError.UNKNOWN,
        )
        WorkInfo.State.CANCELLED -> return null
    }
    return at to PdfUpload(
        id = id,
        fileName = tag(PdfUploadWork.TAG_NAME) ?: "document.pdf",
        sizeBytes = tag(PdfUploadWork.TAG_SIZE)?.toLongOrNull() ?: 0L,
        state = state,
    )
}
