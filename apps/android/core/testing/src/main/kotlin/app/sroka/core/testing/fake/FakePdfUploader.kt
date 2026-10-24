package app.sroka.core.testing.fake

import android.net.Uri
import app.sroka.core.domain.PdfUploader
import app.sroka.core.model.PdfUpload
import app.sroka.core.model.PdfUploadError
import app.sroka.core.model.PdfUploadState
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/**
 * In-memory [PdfUploader]. [enqueue] records [enqueued] and adds a Queued entry (or Failed when
 * [nextError] is set). Drive states from tests/previews with [set], [progress], [complete], [fail].
 */
class FakePdfUploader(initial: List<PdfUpload> = emptyList()) : PdfUploader {
    val state = MutableStateFlow(initial)
    val enqueued = mutableListOf<List<Uri>>()
    val cancelled = mutableListOf<String>()
    var clearedFinished = 0

    /** When set, the next [enqueue] fails every file with this error (client-side rejection). */
    var nextError: PdfUploadError? = null
    private var counter = 0

    override val uploads: Flow<List<PdfUpload>> get() = state

    override suspend fun enqueue(uris: List<Uri>): List<PdfUpload> {
        enqueued += uris
        val error = nextError
        nextError = null
        val created = uris.map {
            val n = ++counter
            PdfUpload(
                id = "upload-$n",
                fileName = "file-$n.pdf",
                sizeBytes = 1_000L * n,
                state = if (error != null) PdfUploadState.Failed(error) else PdfUploadState.Queued,
            )
        }
        state.update { it + created }
        return created
    }

    override suspend fun cancel(id: String) {
        cancelled += id
        state.update { list -> list.filterNot { it.id == id && it.isActive } }
    }

    override fun clearFinished() {
        clearedFinished++
        state.update { list -> list.filter { it.isActive } }
    }

    fun set(id: String, newState: PdfUploadState) =
        state.update { list -> list.map { if (it.id == id) it.copy(state = newState) else it } }

    fun progress(id: String, fraction: Float) = set(id, PdfUploadState.Uploading(fraction))

    fun complete(id: String, itemId: String? = "item-$id", duplicate: Boolean = false) =
        set(id, PdfUploadState.Done(itemId, duplicate))

    fun fail(id: String, error: PdfUploadError) = set(id, PdfUploadState.Failed(error))
}
