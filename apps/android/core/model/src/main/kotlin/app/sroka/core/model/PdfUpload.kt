package app.sroka.core.model

/** Largest PDF the server accepts (`LIMITS.maxPdfBytes`, 50 MiB). */
const val MAX_PDF_BYTES: Long = 50L * 1024 * 1024

/** Why a PDF upload failed. Mapped to string resources in the UI; never carries raw exception text. */
enum class PdfUploadError {
    /** Over [MAX_PDF_BYTES] (client check or HTTP 413). Permanent. */
    TOO_LARGE,

    /** No `%PDF-` header (client check or HTTP 415). Permanent. */
    NOT_PDF,

    /** Account PDF quota (HTTP 409 `storage_full`) or no space left on this device. Permanent. */
    STORAGE_FULL,

    /** Connectivity problem that lasted through all retries. While retrying the upload just shows as Queued. */
    NETWORK,

    /** Server error or unexpected answer (HTTP 5xx/4xx other than the typed ones). */
    UNKNOWN,

    /** Session expired (HTTP 401). */
    AUTH,
}

sealed interface PdfUploadState {
    /** Copied locally and waiting for a network / a free worker. */
    data object Queued : PdfUploadState

    /** Streaming to the server; [progress] is 0..1 of bytes sent. */
    data class Uploading(val progress: Float) : PdfUploadState

    /**
     * Permanent: the temp copy is deleted, nothing retries. Transient problems (offline, 5xx, 401)
     * never show as Failed; the upload stays Queued with backoff and only fails after ~15 attempts.
     */
    data class Failed(val error: PdfUploadError) : PdfUploadState

    /** [itemId] is the library item (new or the existing duplicate); [duplicate] = the file was already saved. */
    data class Done(val itemId: String?, val duplicate: Boolean) : PdfUploadState
}

/** One PDF upload as the UI shows it (library "Uploading N PDFs" row, snackbar). */
data class PdfUpload(
    val id: String,
    val fileName: String,
    val sizeBytes: Long,
    val state: PdfUploadState,
) {
    /** Still in flight: queued or uploading. */
    val isActive: Boolean
        get() = state is PdfUploadState.Queued || state is PdfUploadState.Uploading
}
