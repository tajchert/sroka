package app.sroka.core.data.content

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
import app.sroka.core.model.OfflineState
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SrokaApi
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

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
) : ContentStore {

    private val installer = PackageInstaller()
    private val itemLocks = ConcurrentHashMap<String, Mutex>()

    override fun observeOffline(itemId: String): Flow<OfflineState> =
        itemDao.observeItem(itemId)
            .map { row -> row?.let { deriveOffline(it.item.contentId, it.fileContentId, it.fileState) } ?: OfflineState.NONE }
            .distinctUntilChanged()

    override suspend fun articleHtml(itemId: String): String? = withContext(io) {
        val file = File(paths.articleDir(itemId), PackageInstaller.ARTICLE)
        try {
            if (file.isFile) file.readText() else null
        } catch (_: IOException) {
            null
        }
    }

    override fun articlesDirectory(): File = paths.articles

    override suspend fun downloadNow(itemId: String): DownloadResult = download(itemId)

    override suspend fun storageUsageBytes(): Long = withContext(io) { paths.usageBytes() }

    override suspend fun clearDownloads() {
        contentFileDao.deleteAll()
        withContext(io) { paths.deleteAll() }
    }

    /** Downloads (or confirms) the current package of [itemId]. Safe to call concurrently. */
    suspend fun download(itemId: String): DownloadResult =
        itemLocks.getOrPut(itemId) { Mutex() }.withLock { withContext(io) { downloadLocked(itemId) } }

    /** A9 eviction: packages of archived, non-favorite items archived more than 30 days ago. */
    suspend fun evict() {
        val ids = contentFileDao.evictionCandidates(clock.now() - EVICT_AFTER_MS)
        if (ids.isEmpty()) return
        contentFileDao.delete(ids)
        withContext(io) { ids.forEach(paths::deleteItemFiles) }
    }

    private suspend fun downloadLocked(itemId: String): DownloadResult {
        val item = itemDao.getItem(itemId) ?: return DownloadResult.Failed(RemoteFailure.SERVER)
        val contentId = item.contentId ?: return DownloadResult.NotReady
        val previous = contentFileDao.get(itemId)
        if (previous?.state == ContentState.DOWNLOADED && previous.contentId == contentId &&
            File(paths.articleDir(itemId), PackageInstaller.ARTICLE).isFile
        ) {
            return DownloadResult.Downloaded
        }

        val urls = when (val r = api.contentUrls(itemId)) {
            is ApiResult.Success -> r.value
            is ApiResult.NetworkError -> return DownloadResult.Failed(RemoteFailure.NETWORK)
            is ApiResult.HttpError -> return when {
                r.status == 409 -> DownloadResult.NotReady
                r.status == 401 -> {
                    sessionStore.markExpired()
                    DownloadResult.Failed(RemoteFailure.UNAUTHORIZED)
                }
                else -> {
                    markFailed(previous, itemId, contentId, "http_${r.status}")
                    DownloadResult.Failed(if (r.status == 429) RemoteFailure.RATE_LIMITED else RemoteFailure.SERVER)
                }
            }
        }

        val sameContent = previous?.contentId == contentId
        writeRow(
            ContentFileEntity(
                itemId = itemId,
                contentId = contentId,
                state = ContentState.DOWNLOADING,
                bytes = previous?.bytes ?: 0,
                attempts = if (sameContent) previous.attempts else 0,
                thumbPath = previous?.thumbPath,
                downloadedAt = previous?.downloadedAt,
            ),
        )

        val zip = paths.packageZip(itemId)
        var tooLarge = false
        val downloaded = api.download(urls.packageUrl, zip) { read, _ ->
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
                    markFailed(previous, itemId, contentId, "too_large")
                    return DownloadResult.Failed(RemoteFailure.SERVER)
                }
                restore(previous, itemId)
                return DownloadResult.Failed(RemoteFailure.NETWORK)
            }
            is ApiResult.HttpError -> {
                markFailed(previous, itemId, contentId, "http_${downloaded.status}")
                return DownloadResult.Failed(RemoteFailure.SERVER)
            }
        }

        val installed = installer.install(zip, paths.articles, itemId)
        zip.delete()
        val bytes = when (installed) {
            is PackageInstaller.Result.Invalid -> {
                markFailed(previous, itemId, contentId, installed.reason)
                return DownloadResult.Failed(RemoteFailure.SERVER)
            }
            is PackageInstaller.Result.Installed -> installed.bytes
        }

        val body = try {
            HtmlText.extract(File(paths.articleDir(itemId), PackageInstaller.ARTICLE).readText())
        } catch (_: IOException) {
            ""
        }
        val stillExists = db.tx {
            if (itemDao.getItem(itemId) == null) return@tx false
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
                ),
            )
            true
        }
        if (!stillExists) {
            paths.deleteItemFiles(itemId)
            return DownloadResult.Downloaded
        }

        item.leadImageKey?.let { key -> downloadThumbnail(itemId, urls.baseUrl, key) }
        return DownloadResult.Downloaded
    }

    /** Non-fatal: a missing thumbnail only means the list shows no image. */
    private suspend fun downloadThumbnail(itemId: String, baseUrl: String, key: String) {
        if (PackageInstaller.safeRelativePath(key) == null) return
        val dest = paths.thumb(itemId)
        dest.parentFile?.mkdirs()
        val result = api.download(baseUrl.trimEnd('/') + "/" + key, dest) { read, _ ->
            if (read > MAX_THUMB_BYTES) throw IOException("thumbnail too large")
        }
        if (result !is ApiResult.Success) return
        db.tx {
            val row = contentFileDao.get(itemId) ?: return@tx
            contentFileDao.upsert(row.copy(thumbPath = dest.absolutePath))
        }
    }

    private suspend fun markFailed(previous: ContentFileEntity?, itemId: String, contentId: String, error: String) {
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
            ),
        )
    }

    /** Puts back the row as it was before this attempt (network failures do not count as attempts). */
    private suspend fun restore(previous: ContentFileEntity?, itemId: String) {
        if (previous == null) contentFileDao.delete(itemId) else writeRow(previous)
    }

    /** Upserts unless the item was deleted meanwhile (the FK would fail). */
    private suspend fun writeRow(row: ContentFileEntity) = db.tx {
        if (itemDao.getItem(row.itemId) != null) contentFileDao.upsert(row)
    }

    companion object {
        const val EVICT_AFTER_MS = 30L * 24 * 60 * 60 * 1000
        private const val MAX_THUMB_BYTES = 5L * 1024 * 1024
    }
}
