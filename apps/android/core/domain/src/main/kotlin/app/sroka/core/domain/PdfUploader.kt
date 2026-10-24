package app.sroka.core.domain

import android.net.Uri
import app.sroka.core.model.PdfUpload
import kotlinx.coroutines.flow.Flow

/**
 * Uploads PDFs from the device to `POST /v1/items/pdf` (PDF upload spec, Android). Each file is
 * copied into app storage, then uploaded by its own WorkManager job (network constraint, backoff).
 * After a successful upload a sync pull brings the item into the library through the normal path.
 */
interface PdfUploader {

    /**
     * All uploads known to the app, oldest first: in flight, plus finished ones until [clearFinished].
     * Survives process death (derived from WorkManager state). Empty list = nothing to show.
     */
    val uploads: Flow<List<PdfUpload>>

    /**
     * Copies each [uris] (SAF / share-sheet / drop content URIs) into app storage and enqueues an
     * upload. Files that fail the client checks (over 50 MiB, no `%PDF-` header, device storage
     * full, unreadable) come back as `Failed` entries and are also emitted by
     * [uploads] until [clearFinished]. Returns the new entries in input order.
     */
    suspend fun enqueue(uris: List<Uri>): List<PdfUpload>

    /** Cancels a queued/running upload and deletes its temp copy. No-op for finished ones. */
    suspend fun cancel(id: String)

    /** Forgets finished uploads (done / permanently failed), e.g. after the snackbar was shown. */
    fun clearFinished()
}
