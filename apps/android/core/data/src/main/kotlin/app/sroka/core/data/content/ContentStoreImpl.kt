package app.sroka.core.data.content

import android.util.Log
import app.sroka.core.common.Clock
import app.sroka.core.common.di.Dispatcher
import app.sroka.core.common.di.SrokaDispatchers
import app.sroka.core.data.tx
import app.sroka.core.database.SrokaDatabase
import app.sroka.core.database.dao.ContentFileDao
import app.sroka.core.database.dao.ItemDao
import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ContentState
import app.sroka.core.database.entity.deriveOffline
import app.sroka.core.datastore.SessionStore
import app.sroka.core.domain.ContentStore
import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.model.ItemKind
import app.sroka.core.model.MAX_PDF_BYTES
import app.sroka.core.model.OfflineState
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SrokaApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton

/** Outcome of one package download, richer than the domain [DownloadResult]. */
internal sealed interface DownloadOutcome {
    /** A package was fetched and installed by this call. */
    data object Downloaded : DownloadOutcome

    /** The installed package was already current (another run got there first). */
    data object AlreadyCurrent : DownloadOutcome

    data object NotReady : DownloadOutcome

    data class Failed(val reason: RemoteFailure) : DownloadOutcome

    /** The device is (nearly) out of storage: transient, never counted as an attempt. */
    data object StorageFull : DownloadOutcome

    fun toDomain(): DownloadResult = when (this) {
        Downloaded, AlreadyCurrent -> DownloadResult.Downloaded
        NotReady -> DownloadResult.NotReady
        is Failed -> DownloadResult.Failed(reason)
        // No dedicated domain value yet; the reader treats it like any other failure.
        StorageFull -> DownloadResult.Failed(RemoteFailure.SERVER)
    }
}

/** Cancels queued/running background downloads (implemented by the WorkManager scheduler). */
internal fun interface DownloadCanceller {
    fun cancelDownloads()
}

/**
 * Offline article packages (DECISIONS A9): `contentUrls` → package download → safe unzip + sha256
 * verification → atomic directory swap → FTS body → `content_files` DOWNLOADED; plus the thumbnail.
 * Downloads of the same item are serialized, so the worker and the reader never race.
 */
@Singleton
class ContentStoreImpl @Inject internal constructor(
    private val db: SrokaDatabase,
    private val itemDao: ItemDao,
    private val contentFileDao: ContentFileDao,
    private val api: SrokaApi,
    private val sessionStore: SessionStore,
    private val paths: ContentPaths,
    private val clock: Clock,
    @Dispatcher(SrokaDispatchers.IO) private val io: CoroutineDispatcher,
    private val canceller: DownloadCanceller,
) : ContentStore {

    private val installer = PackageInstaller()
    private val itemLocks = ConcurrentHashMap<String, Mutex>()

    /** Bumped by [clearDownloads]; downloads started earlier must not commit afterwards. */
    private val clearGen = AtomicLong()
    private val clearMutex = Mutex()
    private val recoverMutex = Mutex()

    @Volatile
    private var recovered = false

    /** Free space below which a download is not started (test hook). */
    internal var minFreeBytes: Long = 2 * PackageInstaller.MAX_TOTAL_BYTES

    override fun observeOffline(itemId: String): Flow<OfflineState> =
        itemDao.observeItem(itemId)
            .map { row -> row?.let { deriveOffline(it.item.contentId, it.fileContentId, it.fileState) } ?: OfflineState.NONE }
            .distinctUntilChanged()

    override suspend fun articleHtml(itemId: String): String? = withContext(io) {
        if (!ContentPaths.isSafeId(itemId)) return@withContext null
        val file = File(paths.articleDir(itemId), PackageInstaller.ARTICLE)
        try {
            if (file.isFile) file.readText() else null
        } catch (_: IOException) {
            null
        }
    }

    override fun articlesDirectory(): File = paths.articles

    override suspend fun pdfFile(itemId: String): File? = withContext(io) {
        if (!ContentPaths.isSafeId(itemId)) return@withContext null
        val row = contentFileDao.get(itemId)
        val item = itemDao.getItem(itemId)
        val file = paths.pdfFile(itemId)
        // A row for another content id is stale (the document was replaced on the server).
        if (item?.kind == ItemKind.PDF && row?.state == ContentState.DOWNLOADED && row.contentId == item.contentId && file.isFile) file else null
    }

    override suspend fun downloadNow(itemId: String): DownloadResult = download(itemId).toDomain()

    override suspend fun storageUsageBytes(): Long = withContext(io) { paths.usageBytes() }

    override suspend fun clearDownloads() {
        clearMutex.withLock {
            // In-flight downloads notice the new generation before committing and clean up after
            // themselves; queued work is cancelled so nothing re-fetches what the user just removed.
            clearGen.incrementAndGet()
            canceller.cancelDownloads()
            withContext(io) { paths.deleteAll() }
            db.tx { contentFileDao.deleteAll() }
        }
    }

    /** Current clear generation: a bulk run stops when it changes (see [clearDownloads]). */
    internal fun clearGeneration(): Long = clearGen.get()

    /**
     * Once per process, before any download: rows left in DOWNLOADING by a process that died (or a
     * worker that was killed) go back to QUEUED, and rows whose files vanished (restored backup,
     * cleared storage) are reconciled. Never run while a download of this process is in flight, so
     * concurrent workers cannot reset each other's rows.
     */
    internal suspend fun recoverInterrupted() {
        if (recovered) return
        recoverMutex.withLock {
            if (!recovered) {
                contentFileDao.resetDownloading()
                reconcileFiles()
                recovered = true
            }
        }
    }

    /**
     * A DOWNLOADED row without its article file is dropped (the item shows as remote and becomes
     * eligible again); a thumb path to a missing file is cleared so the thumbnail is re-fetched.
     */
    private suspend fun reconcileFiles() {
        val rows = contentFileDao.all().filter { it.state == ContentState.DOWNLOADED || it.thumbPath != null }
        val (missing, staleThumbs) = withContext(io) {
            val missing = rows.filter {
                it.state == ContentState.DOWNLOADED &&
                    (!ContentPaths.isSafeId(it.itemId) || !hasLocalContent(it.itemId))
            }
            val missingIds = missing.mapTo(HashSet()) { it.itemId }
            missing to rows.filter { it.itemId !in missingIds && it.thumbPath != null && it.thumbPath.let { path -> !File(path).isFile } }
        }
        if (missing.isEmpty() && staleThumbs.isEmpty()) return
        Log.w(TAG, "reconcile: ${missing.size} packages and ${staleThumbs.size} thumbnails missing on disk")
        db.tx {
            contentFileDao.delete(missing.map { it.itemId })
            staleThumbs.forEach { contentFileDao.upsert(it.copy(thumbPath = null, thumbAttempts = 0)) }
        }
        withContext(io) { missing.filter { ContentPaths.isSafeId(it.itemId) }.forEach { paths.deleteItemFiles(it.itemId) } }
    }

    private fun hasLocalContent(itemId: String): Boolean =
        File(paths.articleDir(itemId), PackageInstaller.ARTICLE).isFile || paths.pdfFile(itemId).isFile

    /** Downloads (or confirms) the current package of [itemId]. Safe to call concurrently. */
    internal suspend fun download(itemId: String): DownloadOutcome {
        if (!ContentPaths.isSafeId(itemId)) return DownloadOutcome.Failed(RemoteFailure.SERVER)
        recoverInterrupted()
        val gen = clearGen.get()
        return itemLocks.getOrPut(itemId) { Mutex() }.withLock { withContext(io) { downloadLocked(itemId, gen) } }
    }

    /** A9 eviction: packages of archived, non-favorite items archived more than 30 days ago. */
    suspend fun evict() {
        val before = clock.now() - EVICT_AFTER_MS
        while (true) {
            val ids = contentFileDao.evictionCandidates(before, EVICT_BATCH)
            if (ids.isEmpty()) return
            contentFileDao.delete(ids)
            withContext(io) { ids.forEach(paths::deleteItemFiles) }
        }
    }

    private suspend fun downloadLocked(itemId: String, gen: Long): DownloadOutcome {
        val item = itemDao.getItem(itemId) ?: return DownloadOutcome.Failed(RemoteFailure.SERVER)
        val contentId = item.contentId ?: return DownloadOutcome.NotReady
        val previous = contentFileDao.get(itemId)
        if (item.kind == ItemKind.PDF) return downloadPdfLocked(itemId, contentId, previous, gen)
        if (previous?.state == ContentState.DOWNLOADED && previous.contentId == contentId &&
            File(paths.articleDir(itemId), PackageInstaller.ARTICLE).isFile
        ) {
            retryMissingThumbnail(item.leadImageKey, previous, gen)
            return DownloadOutcome.AlreadyCurrent
        }
        if (paths.usableBytes() < minFreeBytes) return DownloadOutcome.StorageFull

        val urls = when (val r = api.contentUrls(itemId)) {
            is ApiResult.Success -> r.value
            is ApiResult.NetworkError -> return DownloadOutcome.Failed(RemoteFailure.NETWORK)
            is ApiResult.HttpError -> return when {
                r.status == 409 -> DownloadOutcome.NotReady
                r.status == 401 -> {
                    sessionStore.markExpired()
                    DownloadOutcome.Failed(RemoteFailure.UNAUTHORIZED)
                }
                else -> {
                    markFailed(previous, itemId, contentId, "http_${r.status}", gen)
                    DownloadOutcome.Failed(if (r.status == 429) RemoteFailure.RATE_LIMITED else RemoteFailure.SERVER)
                }
            }
        }

        val sameContent = previous?.contentId == contentId
        val marked = writeRow(
            ContentFileEntity(
                itemId = itemId,
                contentId = contentId,
                state = ContentState.DOWNLOADING,
                bytes = previous?.bytes ?: 0,
                attempts = if (sameContent) previous.attempts else 0,
                thumbPath = previous?.thumbPath,
                downloadedAt = previous?.downloadedAt,
                thumbAttempts = previous?.thumbAttempts ?: 0,
            ),
            gen,
        )
        if (!marked) return DownloadOutcome.NotReady

        val outcome = try {
            fetchAndInstall(itemId, contentId, urls.packageUrl, previous, gen)
        } catch (e: CancellationException) {
            // Cancelled worker / sign-out: never leave the row stuck in DOWNLOADING.
            withContext(NonCancellable) {
                paths.packageZip(itemId).delete()
                restore(previous, itemId, gen)
            }
            throw e
        } catch (e: Exception) {
            withContext(NonCancellable) {
                paths.packageZip(itemId).delete()
                markFailed(previous, itemId, contentId, "crash", gen)
            }
            DownloadOutcome.Failed(RemoteFailure.SERVER)
        }
        if (outcome == DownloadOutcome.Downloaded) {
            item.leadImageKey?.let { key ->
                try {
                    downloadThumbnail(itemId, urls.baseUrl, key, gen)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    // Non-fatal: the list simply shows no image (retried later).
                }
            }
        }
        return outcome
    }

    /**
     * PDF items: `documentUrl` of `/content` -> `articles/{id}.tmp` -> `%PDF-` + size check -> moved to
     * `articles/{id}/document.pdf` -> row DOWNLOADED. A 401/403/404/410 on the signed URL (expired)
     * re-fetches the URLs once. No thumbnail, no FTS body.
     */
    private suspend fun downloadPdfLocked(itemId: String, contentId: String, previous: ContentFileEntity?, gen: Long): DownloadOutcome {
        if (previous?.state == ContentState.DOWNLOADED && previous.contentId == contentId && paths.pdfFile(itemId).isFile) {
            return DownloadOutcome.AlreadyCurrent
        }
        if (paths.usableBytes() < minFreeBytes) return DownloadOutcome.StorageFull
        val sameContent = previous?.contentId == contentId
        val marked = writeRow(
            ContentFileEntity(
                itemId = itemId,
                contentId = contentId,
                state = ContentState.DOWNLOADING,
                bytes = previous?.bytes ?: 0,
                attempts = if (sameContent) previous.attempts else 0,
                downloadedAt = previous?.downloadedAt,
            ),
            gen,
        )
        if (!marked) return DownloadOutcome.NotReady
        val temp = paths.pdfTemp(itemId)
        return try {
            fetchPdf(itemId, contentId, temp, previous, gen)
        } catch (e: CancellationException) {
            withContext(NonCancellable) {
                temp.delete()
                restore(previous, itemId, gen)
            }
            throw e
        } catch (e: Exception) {
            withContext(NonCancellable) {
                temp.delete()
                markFailed(previous, itemId, contentId, "crash", gen)
            }
            DownloadOutcome.Failed(RemoteFailure.SERVER)
        }
    }

    private suspend fun fetchPdf(itemId: String, contentId: String, temp: File, previous: ContentFileEntity?, gen: Long): DownloadOutcome {
        var refreshed = false
        while (true) {
            val urls = when (val r = api.contentUrls(itemId)) {
                is ApiResult.Success -> r.value
                is ApiResult.NetworkError -> {
                    restore(previous, itemId, gen)
                    return DownloadOutcome.Failed(RemoteFailure.NETWORK)
                }
                is ApiResult.HttpError -> {
                    if (r.status == 409) {
                        restore(previous, itemId, gen)
                        return DownloadOutcome.NotReady
                    }
                    if (r.status == 401) {
                        restore(previous, itemId, gen)
                        sessionStore.markExpired()
                        return DownloadOutcome.Failed(RemoteFailure.UNAUTHORIZED)
                    }
                    markFailed(previous, itemId, contentId, "http_${r.status}", gen)
                    return DownloadOutcome.Failed(if (r.status == 429) RemoteFailure.RATE_LIMITED else RemoteFailure.SERVER)
                }
            }
            val documentUrl = urls.documentUrl
            if (documentUrl == null) {
                markFailed(previous, itemId, contentId, "no_document_url", gen)
                return DownloadOutcome.Failed(RemoteFailure.SERVER)
            }
            temp.parentFile?.mkdirs()
            var tooLarge = false
            when (val d = api.download(documentUrl, temp) { read, _ ->
                if (read > MAX_PDF_BYTES) {
                    tooLarge = true
                    throw IOException("pdf too large")
                }
            }) {
                is ApiResult.Success -> Unit
                is ApiResult.NetworkError -> {
                    temp.delete()
                    if (tooLarge) {
                        markFailed(previous, itemId, contentId, "too_large", gen)
                        return DownloadOutcome.Failed(RemoteFailure.SERVER)
                    }
                    restore(previous, itemId, gen)
                    return if (isDiskFull(d.cause)) DownloadOutcome.StorageFull else DownloadOutcome.Failed(RemoteFailure.NETWORK)
                }
                is ApiResult.HttpError -> {
                    temp.delete()
                    // Signed URL expired or rejected: ask for fresh ones once.
                    if (!refreshed && d.status in URL_EXPIRED_STATUSES) {
                        refreshed = true
                        continue
                    }
                    markFailed(previous, itemId, contentId, "http_${d.status}", gen)
                    return DownloadOutcome.Failed(RemoteFailure.SERVER)
                }
            }
            if (!looksLikePdf(temp)) {
                temp.delete()
                markFailed(previous, itemId, contentId, "not_pdf", gen)
                return DownloadOutcome.Failed(RemoteFailure.SERVER)
            }
            val bytes = temp.length()
            val dest = paths.pdfFile(itemId)
            val committed = db.tx {
                if (clearGen.get() != gen || itemDao.getItem(itemId) == null) return@tx false
                dest.parentFile?.mkdirs()
                dest.delete()
                if (!temp.renameTo(dest)) return@tx false
                contentFileDao.upsert(
                    ContentFileEntity(
                        itemId = itemId,
                        contentId = contentId,
                        state = ContentState.DOWNLOADED,
                        bytes = bytes,
                        attempts = 0,
                        downloadedAt = clock.now(),
                    ),
                )
                true
            }
            if (!committed) {
                temp.delete()
                paths.deleteItemFiles(itemId)
                return DownloadOutcome.NotReady
            }
            return DownloadOutcome.Downloaded
        }
    }

    private fun looksLikePdf(file: File): Boolean = try {
        file.inputStream().use { input ->
            val head = ByteArray(PDF_SNIFF_BYTES)
            val n = input.read(head)
            n > 0 && String(head, 0, n, Charsets.ISO_8859_1).contains("%PDF-")
        }
    } catch (_: IOException) {
        false
    }

    private suspend fun fetchAndInstall(
        itemId: String,
        contentId: String,
        packageUrl: String,
        previous: ContentFileEntity?,
        gen: Long,
    ): DownloadOutcome {
        val zip = paths.packageZip(itemId)
        var tooLarge = false
        val downloaded = api.download(packageUrl, zip) { read, _ ->
            if (read > PackageInstaller.MAX_TOTAL_BYTES) {
                tooLarge = true
                throw IOException("package too large")
            }
        }
        when (downloaded) {
            is ApiResult.Success -> Unit
            is ApiResult.NetworkError -> {
                zip.delete()
                if (tooLarge) {
                    markFailed(previous, itemId, contentId, "too_large", gen)
                    return DownloadOutcome.Failed(RemoteFailure.SERVER)
                }
                restore(previous, itemId, gen)
                return if (isDiskFull(downloaded.cause)) DownloadOutcome.StorageFull else DownloadOutcome.Failed(RemoteFailure.NETWORK)
            }
            is ApiResult.HttpError -> {
                markFailed(previous, itemId, contentId, "http_${downloaded.status}", gen)
                return DownloadOutcome.Failed(RemoteFailure.SERVER)
            }
        }

        val installed = installer.install(zip, paths.articles, itemId)
        zip.delete()
        val bytes = when (installed) {
            is PackageInstaller.Result.Invalid -> {
                markFailed(previous, itemId, contentId, installed.reason, gen)
                return DownloadOutcome.Failed(RemoteFailure.SERVER)
            }
            // Local I/O trouble (typically a full disk) is not the package's fault: no attempt counted.
            PackageInstaller.Result.IoError -> {
                restore(previous, itemId, gen)
                return DownloadOutcome.StorageFull
            }
            is PackageInstaller.Result.Installed -> installed.bytes
        }

        val body = try {
            HtmlText.extract(File(paths.articleDir(itemId), PackageInstaller.ARTICLE).readText())
        } catch (_: IOException) {
            ""
        }
        val committed = db.tx {
            if (clearGen.get() != gen || itemDao.getItem(itemId) == null) return@tx false
            itemDao.setFtsBody(itemId, body)
            contentFileDao.upsert(
                ContentFileEntity(
                    itemId = itemId,
                    contentId = contentId,
                    state = ContentState.DOWNLOADED,
                    bytes = bytes,
                    attempts = 0,
                    downloadedAt = clock.now(),
                    thumbPath = previous?.thumbPath,
                    thumbAttempts = previous?.thumbAttempts ?: 0,
                ),
            )
            true
        }
        if (!committed) {
            // Cleared or deleted meanwhile: do not leave files without a row.
            paths.deleteItemFiles(itemId)
            return DownloadOutcome.NotReady
        }
        return DownloadOutcome.Downloaded
    }

    /** Best effort: a DOWNLOADED row whose thumbnail never arrived gets another try (capped). */
    private suspend fun retryMissingThumbnail(leadImageKey: String?, row: ContentFileEntity, gen: Long) {
        if (leadImageKey == null || row.thumbAttempts >= THUMB_MAX_ATTEMPTS) return
        if (row.thumbPath != null && File(row.thumbPath!!).isFile) return
        try {
            when (val r = api.contentUrls(row.itemId)) {
                is ApiResult.Success -> downloadThumbnail(row.itemId, r.value.baseUrl, leadImageKey, gen)
                is ApiResult.NetworkError -> Unit
                is ApiResult.HttpError -> if (r.status != 401) bumpThumbAttempts(row.itemId, gen)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // best effort
        }
    }

    /**
     * Non-fatal: a missing thumbnail only means the list shows no image. Downloads to a temp file and
     * moves it into place inside the transaction that confirms the item and its row still exist, so a
     * sign-out or "Remove downloads" in between cannot leave an orphan behind.
     */
    private suspend fun downloadThumbnail(itemId: String, baseUrl: String, key: String, gen: Long) {
        if (PackageInstaller.safeRelativePath(key) == null) return
        val temp = paths.thumbTemp(itemId)
        try {
            temp.parentFile?.mkdirs()
            val result = api.download(baseUrl.trimEnd('/') + "/" + key, temp) { read, _ ->
                if (read > MAX_THUMB_BYTES) throw IOException("thumbnail too large")
            }
            when (result) {
                is ApiResult.Success -> Unit
                // A blip is retried later without counting; anything else counts toward the cap.
                is ApiResult.NetworkError -> {
                    temp.delete()
                    return
                }
                is ApiResult.HttpError -> {
                    temp.delete()
                    bumpThumbAttempts(itemId, gen)
                    return
                }
            }
            val dest = paths.thumb(itemId)
            val installed = db.tx {
                val row = contentFileDao.get(itemId)
                if (clearGen.get() != gen || row == null || itemDao.getItem(itemId) == null) return@tx false
                dest.parentFile?.mkdirs()
                dest.delete()
                if (!temp.renameTo(dest)) return@tx false
                contentFileDao.upsert(row.copy(thumbPath = dest.absolutePath))
                true
            }
            if (!installed) temp.delete()
        } catch (e: Throwable) {
            temp.delete()
            throw e
        }
    }

    private suspend fun bumpThumbAttempts(itemId: String, gen: Long) {
        db.tx {
            val row = contentFileDao.get(itemId) ?: return@tx
            if (clearGen.get() == gen) contentFileDao.upsert(row.copy(thumbAttempts = row.thumbAttempts + 1))
        }
    }

    private suspend fun markFailed(previous: ContentFileEntity?, itemId: String, contentId: String, error: String, gen: Long) {
        val attempts = if (previous?.contentId == contentId) previous.attempts + 1 else 1
        writeRow(
            ContentFileEntity(
                itemId = itemId,
                contentId = contentId,
                state = ContentState.FAILED,
                bytes = previous?.bytes ?: 0,
                attempts = attempts,
                error = error,
                downloadedAt = previous?.downloadedAt,
                thumbPath = previous?.thumbPath,
                thumbAttempts = previous?.thumbAttempts ?: 0,
            ),
            gen,
        )
    }

    /** Puts back the row as it was before this attempt (network failures do not count as attempts). */
    private suspend fun restore(previous: ContentFileEntity?, itemId: String, gen: Long) {
        if (previous == null) db.tx { contentFileDao.delete(itemId) } else writeRow(previous, gen)
    }

    /** Upserts unless the item was deleted or downloads were cleared meanwhile; false = not written. */
    private suspend fun writeRow(row: ContentFileEntity, gen: Long): Boolean = db.tx {
        if (clearGen.get() != gen || itemDao.getItem(row.itemId) == null) return@tx false
        contentFileDao.upsert(row)
        true
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

    companion object {
        const val EVICT_AFTER_MS = 30L * 24 * 60 * 60 * 1000
        private const val EVICT_BATCH = 500
        private const val MAX_THUMB_BYTES = 5L * 1024 * 1024
        const val THUMB_MAX_ATTEMPTS = 3
        private const val PDF_SNIFF_BYTES = 1024
        private val URL_EXPIRED_STATUSES = setOf(401, 403, 404, 410)
        private const val TAG = "SrokaContent"
    }
}
