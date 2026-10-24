package app.sroka.core.data.upload

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import app.sroka.core.common.Clock
import app.sroka.core.common.di.Dispatcher
import app.sroka.core.common.di.SrokaDispatchers
import app.sroka.core.data.content.ContentPaths
import app.sroka.core.data.sync.SyncWork
import app.sroka.core.domain.PdfUploader
import app.sroka.core.model.MAX_PDF_BYTES
import app.sroka.core.model.PdfUpload
import app.sroka.core.model.PdfUploadError
import app.sroka.core.model.PdfUploadState
import app.sroka.core.model.newUuidV7
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/** Work names, tags and data keys of PDF upload jobs. */
object PdfUploadWork {
    const val TAG = "sroka-tag-pdf-upload"
    const val UNIQUE_PREFIX = "sroka-pdf-upload-"

    // Tags carry the display metadata so it survives until the work is pruned (input data is not exposed by WorkInfo).
    const val TAG_ID = "pdf-id:"
    const val TAG_NAME = "pdf-name:"
    const val TAG_SIZE = "pdf-size:"
    const val TAG_AT = "pdf-at:"

    const val KEY_ID = "id"
    const val KEY_NAME = "name"
    const val KEY_SENT = "sent"
    const val KEY_TOTAL = "total"
    const val KEY_ITEM_ID = "itemId"
    const val KEY_DUPLICATE = "duplicate"
    const val KEY_ERROR = "error"
}

/**
 * [PdfUploader] on WorkManager: one unique [PdfUploadWorker] per file. The list state is derived from
 * `WorkInfo`s (so it survives process death) merged with entries rejected before any work existed.
 */
@Singleton
class PdfUploaderImpl @Inject internal constructor(
    @ApplicationContext private val context: Context,
    private val paths: ContentPaths,
    private val clock: Clock,
    @Dispatcher(SrokaDispatchers.IO) private val io: CoroutineDispatcher,
) : PdfUploader {

    private val workManager: WorkManager get() = WorkManager.getInstance(context)
    private val rejected = MutableStateFlow<List<Entry>>(emptyList())

    private class Entry(val at: Long, val upload: PdfUpload)

    override val uploads: Flow<List<PdfUpload>> by lazy {
        combine(workManager.getWorkInfosByTagFlow(PdfUploadWork.TAG), rejected) { infos, local ->
            (infos.mapNotNull { info -> pdfUploadOf(info)?.let { Entry(it.first, it.second) } } + local).sortedBy { it.at }.map { it.upload }
        }
    }

    override suspend fun enqueue(uris: List<Uri>): List<PdfUpload> = withContext(io) {
        uris.map { uri -> enqueueOne(uri) }
    }

    private suspend fun enqueueOne(uri: Uri): PdfUpload {
        val now = clock.now()
        val id = newUuidV7(now)
        val (displayName, declaredSize) = describe(uri)
        val name = cleanName(displayName ?: uri.lastPathSegment)
        fun reject(error: PdfUploadError, size: Long = declaredSize ?: 0): PdfUpload {
            val upload = PdfUpload(id, name, size, PdfUploadState.Failed(error))
            rejected.value = rejected.value + Entry(now, upload)
            return upload
        }
        if (declaredSize != null && declaredSize > MAX_PDF_BYTES) return reject(PdfUploadError.TOO_LARGE)
        val dest = paths.pdfUploadFile(id)
        val size = when (val copied = copyToStorage(uri, dest)) {
            is CopyResult.Copied -> copied.bytes
            is CopyResult.Rejected -> {
                dest.delete()
                return reject(copied.error)
            }
        }
        val request = OneTimeWorkRequestBuilder<PdfUploadWorker>()
            .setInputData(workDataOf(PdfUploadWork.KEY_ID to id, PdfUploadWork.KEY_NAME to name))
            .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
            .addTag(SyncWork.TAG_ALL)
            .addTag(PdfUploadWork.TAG)
            .addTag(PdfUploadWork.TAG_ID + id)
            .addTag(PdfUploadWork.TAG_NAME + name)
            .addTag(PdfUploadWork.TAG_SIZE + size)
            .addTag(PdfUploadWork.TAG_AT + now)
            .build()
        workManager.enqueueUniqueWork(PdfUploadWork.UNIQUE_PREFIX + id, ExistingWorkPolicy.KEEP, request)
        return PdfUpload(id, name, size, PdfUploadState.Queued)
    }

    override suspend fun cancel(id: String) {
        if (!ContentPaths.isSafeId(id)) return
        workManager.cancelUniqueWork(PdfUploadWork.UNIQUE_PREFIX + id)
        withContext(io) { paths.pdfUploadFile(id).delete() }
        rejected.value = rejected.value.filterNot { it.upload.id == id }
    }

    override fun clearFinished() {
        rejected.value = emptyList()
        workManager.pruneWork()
    }

    private fun describe(uri: Uri): Pair<String?, Long?> = try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (!c.moveToFirst()) return null to null
            val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
            (if (nameIdx >= 0) c.getString(nameIdx) else null) to
                (if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx).takeIf { it >= 0 } else null)
        } ?: (null to null)
    } catch (_: Exception) {
        null to null
    }

    private sealed interface CopyResult {
        data class Copied(val bytes: Long) : CopyResult
        data class Rejected(val error: PdfUploadError) : CopyResult
    }

    /** Streams [uri] into [dest] with a hard size cap and a `%PDF-` sniff of the first KiB. */
    private fun copyToStorage(uri: Uri, dest: File): CopyResult = try {
        dest.parentFile?.mkdirs()
        val input = context.contentResolver.openInputStream(uri) ?: return CopyResult.Rejected(PdfUploadError.UNKNOWN)
        input.use { source ->
            dest.outputStream().use { sink ->
                val buffer = ByteArray(BUFFER_BYTES)
                var total = 0L
                var sniffed = false
                val head = StringBuilder()
                while (true) {
                    val n = source.read(buffer)
                    if (n < 0) break
                    if (!sniffed) {
                        if (head.length < SNIFF_BYTES) head.append(String(buffer, 0, minOf(n, SNIFF_BYTES - head.length), Charsets.ISO_8859_1))
                        if (head.contains("%PDF-")) sniffed = true
                    }
                    total += n
                    if (total > MAX_PDF_BYTES) return CopyResult.Rejected(PdfUploadError.TOO_LARGE)
                    sink.write(buffer, 0, n)
                }
                if (total == 0L || !sniffed) return CopyResult.Rejected(PdfUploadError.NOT_PDF)
                CopyResult.Copied(total)
            }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: IOException) {
        CopyResult.Rejected(if (isDiskFull(e)) PdfUploadError.STORAGE_FULL else PdfUploadError.UNKNOWN)
    } catch (_: Exception) {
        CopyResult.Rejected(PdfUploadError.UNKNOWN)
    }

    private fun isDiskFull(e: Throwable): Boolean {
        var t: Throwable? = e
        while (t != null) {
            val m = t.message.orEmpty()
            if (m.contains("ENOSPC") || m.contains("No space left", ignoreCase = true)) return true
            t = t.cause
        }
        return false
    }

    private companion object {
        const val BACKOFF_SECONDS = 30L
        const val BUFFER_BYTES = 64 * 1024
        const val SNIFF_BYTES = 1024
        const val MAX_NAME = 255

        fun cleanName(raw: String?): String {
            val base = raw?.substringAfterLast('/')?.trim().orEmpty().ifEmpty { "document.pdf" }
            return if (base.length <= MAX_NAME) base else base.take(MAX_NAME - 4) + ".pdf"
        }
    }
}
