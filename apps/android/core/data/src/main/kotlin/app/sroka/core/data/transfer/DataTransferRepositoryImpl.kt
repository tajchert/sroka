package app.sroka.core.data.transfer

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import app.sroka.core.common.di.Dispatcher
import app.sroka.core.common.di.SrokaDispatchers
import app.sroka.core.datastore.SessionStore
import app.sroka.core.domain.DataTransferRepository
import app.sroka.core.domain.ExportError
import app.sroka.core.domain.ExportResult
import app.sroka.core.domain.ImportError
import app.sroka.core.domain.ImportStartResult
import app.sroka.core.domain.PickedFile
import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import app.sroka.core.model.ImportJob
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SrokaApi
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
internal class DataTransferRepositoryImpl @Inject constructor(
    @ApplicationContext private val context: Context,
    private val api: SrokaApi,
    private val store: ImportJobStore,
    private val scheduler: ImportScheduler,
    private val sessionStore: SessionStore,
    @Dispatcher(SrokaDispatchers.IO) private val io: CoroutineDispatcher,
) : DataTransferRepository {

    private val resolver: ContentResolver get() = context.contentResolver

    override fun activeImport(): Flow<ImportJob?> = store.observe()

    override suspend fun dismissImport() = store.clear()

    override fun fileInfo(uri: String): PickedFile? = runCatching { queryInfo(Uri.parse(uri)) }.getOrNull()

    override suspend fun startImport(uri: String, format: ImportFormat): ImportStartResult {
        val parsed = Uri.parse(uri)
        val info = fileInfo(uri)
        val max = DataTransferRepository.MAX_IMPORT_BYTES
        if ((info?.sizeBytes ?: 0L) > max) return failed(ImportError.TOO_LARGE)

        val name = info?.name ?: "import"
        val temp = File(File(context.cacheDir, "imports").apply { mkdirs() }, "${UUID.randomUUID()}-${safeName(name)}")
        try {
            val copied = withContext(io) { copyLimited(parsed, temp, max) }
            when {
                copied == null -> return failed(ImportError.BAD_FILE)
                copied > max -> return failed(ImportError.TOO_LARGE)
                copied == 0L -> return failed(ImportError.BAD_FILE)
            }
            val mime = resolver.getType(parsed) ?: guessMime(name)
            return when (val r = api.createImport(temp, name, mime, format)) {
                is ApiResult.Success -> {
                    val job = r.value.toImportJob(format)
                    store.set(job)
                    scheduler.enqueue(job.id)
                    ImportStartResult.Started(job)
                }
                is ApiResult.NetworkError -> failed(ImportError.NETWORK)
                is ApiResult.HttpError -> failed(
                    when (r.status) {
                        401 -> {
                            sessionStore.markExpired()
                            ImportError.SIGNED_OUT
                        }
                        413 -> ImportError.TOO_LARGE
                        429 -> ImportError.RATE_LIMITED
                        400, 415 -> ImportError.BAD_FILE
                        in 500..599 -> ImportError.UNAVAILABLE
                        else -> ImportError.UNKNOWN
                    },
                )
            }
        } finally {
            withContext(io) { temp.delete() }
        }
    }

    override suspend fun export(format: ExportFormat): ExportResult {
        val dir = File(context.cacheDir, "exports")
        val tmp = File(dir, DOWNLOAD_NAME)
        withContext(io) {
            dir.listFiles()?.forEach { it.delete() }
            dir.mkdirs()
        }
        return when (val r = api.export(format, tmp)) {
            is ApiResult.Success -> withContext(io) {
                val target = File(dir, r.value.fileName)
                target.delete()
                if (tmp.renameTo(target)) {
                    ExportResult.Ready(target.absolutePath, r.value.fileName, r.value.bytes)
                } else {
                    tmp.delete()
                    ExportResult.Failed(ExportError.SERVER)
                }
            }
            is ApiResult.NetworkError -> ExportResult.Failed(ExportError.NETWORK)
            is ApiResult.HttpError -> ExportResult.Failed(
                if (r.status == 401) {
                    sessionStore.markExpired()
                    ExportError.SIGNED_OUT
                } else {
                    ExportError.SERVER
                },
            )
        }
    }

    private fun failed(reason: ImportError) = ImportStartResult.Failed(reason)

    /** Bytes copied, or null when the source is unreadable. Stops once more than [max] bytes were seen. */
    private fun copyLimited(uri: Uri, dest: File, max: Long): Long? {
        try {
            val input = resolver.openInputStream(uri) ?: return null
            input.use { source ->
                dest.outputStream().use { out ->
                    val buffer = ByteArray(16 * 1024)
                    var total = 0L
                    while (true) {
                        val n = source.read(buffer)
                        if (n < 0) break
                        total += n
                        if (total > max) return total
                        out.write(buffer, 0, n)
                    }
                    return total
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: IOException) {
            return null
        } catch (_: SecurityException) {
            return null
        }
    }

    private fun queryInfo(uri: Uri): PickedFile? {
        if (uri.scheme == ContentResolver.SCHEME_FILE) {
            val f = File(uri.path ?: return null)
            return PickedFile(f.name, f.length())
        }
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (!c.moveToFirst()) return null
            val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
            val name = if (nameIdx >= 0) c.getString(nameIdx) else null
            val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else null
            return PickedFile(name ?: uri.lastPathSegment ?: "import", size)
        }
        return null
    }

    private fun safeName(name: String): String = name.replace(Regex("[^A-Za-z0-9._-]"), "_").takeLast(80)

    private fun guessMime(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "csv" -> "text/csv"
        "html", "htm" -> "text/html"
        "zip" -> "application/zip"
        else -> "application/octet-stream"
    }

    private companion object {
        const val DOWNLOAD_NAME = "download.tmp"
    }
}
