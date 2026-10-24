package app.sroka.core.data.upload

import app.sroka.core.model.MAX_PDF_BYTES
import app.sroka.core.model.PdfUploadError
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SrokaApi
import java.io.File

/** Result of one upload attempt, already mapped to the retry rules. */
internal sealed interface UploadOutcome {
    data class Uploaded(val itemId: String, val duplicate: Boolean) : UploadOutcome

    /** Keep the file and try again later (WorkManager backoff). */
    data class Transient(val error: PdfUploadError) : UploadOutcome

    /** Never retry: delete the file and report [error]. */
    data class Permanent(val error: PdfUploadError) : UploadOutcome
}

/**
 * One `POST /v1/items/pdf` attempt and its error mapping (kept apart from the Worker so it is unit-testable):
 * 413 -> TOO_LARGE, 415 -> NOT_PDF, 409 `storage_full` -> STORAGE_FULL, other 4xx -> UNKNOWN (permanent);
 * 401 -> AUTH, 429 / 5xx / 408 -> UNKNOWN, I/O -> NETWORK (all transient).
 */
internal class PdfUploadProcessor(private val api: SrokaApi) {

    suspend fun upload(file: File, fileName: String, source: String, onProgress: (Long, Long) -> Unit): UploadOutcome {
        if (!file.isFile) return UploadOutcome.Permanent(PdfUploadError.UNKNOWN)
        if (file.length() > MAX_PDF_BYTES) return UploadOutcome.Permanent(PdfUploadError.TOO_LARGE)
        return when (val r = api.uploadPdf(file, fileName, source = source, onProgress = onProgress)) {
            is ApiResult.Success -> UploadOutcome.Uploaded(r.value.item.id, duplicate = !r.value.created)
            is ApiResult.NetworkError -> UploadOutcome.Transient(PdfUploadError.NETWORK)
            is ApiResult.HttpError -> when {
                r.status == 413 -> UploadOutcome.Permanent(PdfUploadError.TOO_LARGE)
                r.status == 415 -> UploadOutcome.Permanent(PdfUploadError.NOT_PDF)
                r.status == 409 && r.code == "storage_full" -> UploadOutcome.Permanent(PdfUploadError.STORAGE_FULL)
                r.status == 401 -> UploadOutcome.Transient(PdfUploadError.AUTH)
                r.status == 408 || r.status == 429 || r.status >= 500 -> UploadOutcome.Transient(PdfUploadError.UNKNOWN)
                else -> UploadOutcome.Permanent(PdfUploadError.UNKNOWN)
            }
        }
    }
}
