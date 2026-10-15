package app.sroka.core.data

import app.sroka.core.data.content.ContentStoreImpl
import app.sroka.core.data.content.DownloadCanceller
import app.sroka.core.data.content.DownloadOutcome
import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ContentState
import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.OfflineState
import app.sroka.core.network.ApiResult
import app.sroka.core.network.ContentUrlsDto
import app.sroka.core.network.SrokaApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

internal class ContentStoreTest : DataTestBase() {

    private fun contentUrls() {
        val base = server.url("/p/c/").toString()
        enqueueJson("""{"articleUrl":"${base}article.html","baseUrl":"$base","packageUrl":"${base}package.zip","expiresAt":1}""")
    }

    @Test fun downloadsVerifiesAndIndexesPackage() = runBlocking {
        itemDao.upsertItem(entity("a", leadImageKey = "thumb.webp"))
        contentUrls()
        enqueueBytes(TestPackages.packageBytes("<h1>Magpies</h1><p>Corvids are clever &amp; curious</p>"))
        enqueueBytes(byteArrayOf(9, 9))
        assertEquals(DownloadResult.Downloaded, contentStore.downloadNow("a"))

        assertEquals("/v1/items/a/content", takeRequest().url.encodedPath)
        val pkg = takeRequest()
        assertEquals("/p/c/package.zip", pkg.url.encodedPath)
        assertNull(pkg.headers["Authorization"])
        assertEquals("/p/c/thumb.webp", takeRequest().url.encodedPath)

        val row = contentFileDao.get("a")!!
        assertEquals(ContentState.DOWNLOADED, row.state)
        assertTrue(row.bytes > 0)
        assertEquals(paths.thumb("a").absolutePath, row.thumbPath)
        assertEquals(OfflineState.DOWNLOADED, contentStore.observeOffline("a").first())
        assertTrue(contentStore.articleHtml("a")!!.contains("Magpies"))
        assertTrue(contentStore.storageUsageBytes() > 0)
        // Body text is searchable offline.
        val hits = itemDao.pagedItems(ItemQuery(LibraryTab.MY_LIST, search = "curious"))
            .load(androidx.paging.PagingSource.LoadParams.Refresh(null, 10, false))
        assertEquals(listOf("a"), (hits as androidx.paging.PagingSource.LoadResult.Page).data.map { it.id })

        // Already current: no network.
        assertEquals(DownloadResult.Downloaded, contentStore.downloadNow("a"))
        assertEquals(3, server.requestCount)
    }

    @Test fun shaMismatchMarksFailedAndKeepsOldContent() = runBlocking {
        itemDao.upsertItem(entity("a", contentId = "c-new"))
        paths.articleDir("a").mkdirs()
        File(paths.articleDir("a"), "article.html").writeText("old")
        contentFileDao.upsert(ContentFileEntity("a", "c-old", ContentState.DOWNLOADED, bytes = 3))
        contentUrls()
        enqueueBytes(TestPackages.packageBytes("new", corruptSha = true))
        assertEquals(DownloadResult.Failed(RemoteFailure.SERVER), contentStore.downloadNow("a"))
        val row = contentFileDao.get("a")!!
        assertEquals(ContentState.FAILED, row.state)
        assertEquals(1, row.attempts)
        assertEquals("sha256_mismatch", row.error)
        assertEquals("old", contentStore.articleHtml("a"))
    }

    @Test fun notParsedIsNotReadyAndNetworkErrorRestoresRow() = runBlocking {
        itemDao.upsertItem(entity("a"))
        enqueueJson("""{"error":"not_parsed"}""", code = 409)
        assertEquals(DownloadResult.NotReady, contentStore.downloadNow("a"))
        assertNull(contentFileDao.get("a"))

        contentUrls()
        server.enqueue(mockwebserver3.MockResponse.Builder().code(200).body("x").onResponseStart(mockwebserver3.SocketEffect.CloseSocket()).build())
        val r = contentStore.downloadNow("a")
        assertTrue(r.toString(), r == DownloadResult.Failed(RemoteFailure.NETWORK) || r == DownloadResult.Failed(RemoteFailure.SERVER))
        if (r == DownloadResult.Failed(RemoteFailure.NETWORK)) assertNull(contentFileDao.get("a"))
        assertFalse(paths.articleDir("a").exists())
    }

    @Test fun eligibleIsNewestFirstUnreadOrFavorite() = runBlocking {
        itemDao.upsertItem(entity("old", savedAt = 1))
        itemDao.upsertItem(entity("new", savedAt = 3))
        itemDao.upsertItem(entity("archived", savedAt = 4, status = ItemStatus.ARCHIVED))
        itemDao.upsertItem(entity("archivedFav", savedAt = 2, status = ItemStatus.ARCHIVED, favorite = true))
        itemDao.upsertItem(entity("noContent", savedAt = 5, contentId = null))
        assertEquals(listOf("new", "archivedFav", "old"), contentFileDao.eligibleForDownload().map { it.itemId })
    }

    @Test fun evictsOldArchivedPackages() = runBlocking {
        itemDao.upsertItem(entity("a", status = ItemStatus.ARCHIVED, archivedAt = now - 31L * 86_400_000))
        itemDao.upsertItem(entity("b", status = ItemStatus.ARCHIVED, archivedAt = now - 86_400_000))
        for (id in listOf("a", "b")) {
            contentFileDao.upsert(ContentFileEntity(id, "c-$id", ContentState.DOWNLOADED))
            paths.articleDir(id).mkdirs()
        }
        contentStore.evict()
        assertNull(contentFileDao.get("a"))
        assertFalse(paths.articleDir("a").exists())
        assertTrue(paths.articleDir("b").exists())

        contentStore.clearDownloads()
        assertNull(contentFileDao.get("b"))
        assertEquals(0, contentStore.storageUsageBytes())
    }

    // ---- robustness -------------------------------------------------------------------------

    /** Scripted API: package/thumbnail downloads can be gated, failed, or hung. */
    private class StubApi(
        private val base: String = "http://x/p/",
        var onDownload: suspend (url: String, dest: File) -> ApiResult<Unit> = { _, dest ->
            dest.writeBytes(TestPackages.packageBytes("<p>Hello world</p>"))
            ApiResult.Success(Unit)
        },
    ) : SrokaApi {
        var contentUrlRequests = 0
        override suspend fun contentUrls(itemId: String): ApiResult<ContentUrlsDto> {
            contentUrlRequests++
            return ApiResult.Success(ContentUrlsDto("${base}article.html", base, "${base}package.zip"))
        }
        override suspend fun download(url: String, dest: File, onProgress: (Long, Long) -> Unit): ApiResult<Unit> {
            dest.parentFile?.mkdirs()
            return onDownload(url, dest)
        }
        override suspend fun sendOtp(email: String) = error("unused")
        override suspend fun signIn(email: String, otp: String) = error("unused")
        override suspend fun signOut() = error("unused")
        override suspend fun push(deviceId: String, ops: List<JsonObject>) = error("unused")
        override suspend fun pull(cursor: Long, limit: Int, full: Boolean) = error("unused")
        override suspend fun getItem(itemId: String) = error("unused")
        override suspend fun me() = error("unused")
        override suspend fun config() = error("unused")
        override suspend fun deleteAccount() = error("unused")
    }

    private fun storeWith(api: SrokaApi) =
        ContentStoreImpl(db, itemDao, contentFileDao, api, sessionStore, paths, clock, Dispatchers.IO, DownloadCanceller { cancelledDownloads++ })

    private suspend fun awaitState(itemId: String, state: ContentState) {
        withTimeout(5_000) { while (contentFileDao.get(itemId)?.state != state) delay(10) }
    }

    @Test fun cancelledDownloadDoesNotLeaveDownloadingRow() = runBlocking {
        itemDao.upsertItem(entity("a"))
        val api = StubApi(onDownload = { _, _ -> awaitCancellation() })
        val store = storeWith(api)
        val job = launch(Dispatchers.IO) { store.download("a") }
        awaitState("a", ContentState.DOWNLOADING)
        job.cancelAndJoin()
        assertNull(contentFileDao.get("a")) // no previous row: back to "none"

        // with a previous FAILED row the row is restored as it was
        contentFileDao.upsert(ContentFileEntity("a", "c-a", ContentState.FAILED, attempts = 2, error = "http_500"))
        val job2 = launch(Dispatchers.IO) { store.download("a") }
        awaitState("a", ContentState.DOWNLOADING)
        job2.cancelAndJoin()
        val row = contentFileDao.get("a")!!
        assertEquals(ContentState.FAILED, row.state)
        assertEquals(2, row.attempts)
        assertFalse(paths.packageZip("a").exists())
        // and it is retried normally afterwards
        api.onDownload = { _, dest -> dest.writeBytes(TestPackages.packageBytes("<p>ok</p>")); ApiResult.Success(Unit) }
        assertEquals(DownloadOutcome.Downloaded, store.download("a"))
    }

    @Test fun nonCancellationFailureMarksFailedInsteadOfStaying() = runBlocking {
        itemDao.upsertItem(entity("a"))
        val store = storeWith(StubApi(onDownload = { _, _ -> throw IllegalStateException("boom") }))
        assertEquals(DownloadOutcome.Failed(RemoteFailure.SERVER), store.download("a"))
        assertEquals(ContentState.FAILED, contentFileDao.get("a")!!.state)
    }

    @Test fun interruptedRowsAreRecoveredOncePerProcess() = runBlocking {
        itemDao.upsertItem(entity("a"))
        contentFileDao.upsert(ContentFileEntity("a", "c-a", ContentState.DOWNLOADING))
        contentStore.recoverInterrupted()
        assertEquals(ContentState.QUEUED, contentFileDao.get("a")!!.state)
        // a second call is a no-op: a row another worker is downloading is left alone
        contentFileDao.upsert(ContentFileEntity("a", "c-a", ContentState.DOWNLOADING))
        contentStore.recoverInterrupted()
        assertEquals(ContentState.DOWNLOADING, contentFileDao.get("a")!!.state)
    }

    @Test fun missingFilesAreReconciledAtStartup() = runBlocking {
        itemDao.upsertItem(entity("a"))
        itemDao.upsertItem(entity("b"))
        // a: DOWNLOADED but its package directory is gone
        contentFileDao.upsert(ContentFileEntity("a", "c-a", ContentState.DOWNLOADED, thumbPath = paths.thumb("a").path))
        // b: package present, thumbnail file gone
        File(paths.articleDir("b"), "article.html").apply { parentFile!!.mkdirs(); writeText("<p>b</p>") }
        contentFileDao.upsert(ContentFileEntity("b", "c-b", ContentState.DOWNLOADED, thumbPath = paths.thumb("b").path, thumbAttempts = 2))
        contentStore.recoverInterrupted()
        assertNull(contentFileDao.get("a"))
        val b = contentFileDao.get("b")!!
        assertEquals(ContentState.DOWNLOADED, b.state)
        assertNull(b.thumbPath)
        assertEquals(0, b.thumbAttempts)
    }

    @Test fun diskFullIsStorageNotNetworkAndNotAnAttempt() = runBlocking {
        itemDao.upsertItem(entity("a"))
        val store = storeWith(StubApi(onDownload = { _, _ -> ApiResult.NetworkError(java.io.IOException("write failed: ENOSPC (No space left on device)")) }))
        assertEquals(DownloadOutcome.StorageFull, store.download("a"))
        assertNull(contentFileDao.get("a"))

        // not enough free space: nothing is requested at all
        val api = StubApi()
        val low = storeWith(api).also { it.minFreeBytes = Long.MAX_VALUE }
        assertEquals(DownloadOutcome.StorageFull, low.download("a"))
        assertEquals(0, api.contentUrlRequests)
        assertNull(contentFileDao.get("a"))
    }

    @Test fun installIoErrorIsStorageNotAFailedAttempt() = runBlocking {
        itemDao.upsertItem(entity("a"))
        // The articles root is a plain file, so the installer cannot create its tmp dir (like ENOSPC).
        paths.articles.parentFile!!.mkdirs()
        paths.articles.writeText("not a directory")
        assertEquals(DownloadOutcome.StorageFull, storeWith(StubApi()).download("a"))
        assertNull(contentFileDao.get("a"))
    }

    @Test fun clearDownloadsDuringADownloadLeavesNoRowOrFiles() = runBlocking {
        itemDao.upsertItem(entity("a"))
        val gate = CompletableDeferred<Unit>()
        val api = StubApi(onDownload = { _, dest ->
            gate.await()
            dest.parentFile?.mkdirs() // like the real client, after the response arrives
            dest.writeBytes(TestPackages.packageBytes("<p>late</p>"))
            ApiResult.Success(Unit)
        })
        val store = storeWith(api)
        val result = async(Dispatchers.IO) { store.download("a") }
        awaitState("a", ContentState.DOWNLOADING)
        store.clearDownloads()
        assertEquals(1, cancelledDownloads)
        gate.complete(Unit)
        assertEquals(DownloadOutcome.NotReady, result.await())
        assertNull(contentFileDao.get("a"))
        assertFalse(paths.articleDir("a").exists())
        assertEquals(0, store.storageUsageBytes())
    }

    @Test fun missingThumbnailIsRetriedAndCappedAndNeverOrphaned() = runBlocking {
        itemDao.upsertItem(entity("a", leadImageKey = "thumb.webp"))
        var thumbOk = false
        val api = StubApi(onDownload = { url, dest ->
            if (url.endsWith("thumb.webp")) {
                if (thumbOk) { dest.writeBytes(byteArrayOf(1, 2)); ApiResult.Success(Unit) } else ApiResult.HttpError(404, null, null)
            } else {
                dest.writeBytes(TestPackages.packageBytes("<p>x</p>")); ApiResult.Success(Unit)
            }
        })
        val store = storeWith(api)
        assertEquals(DownloadOutcome.Downloaded, store.download("a"))
        var row = contentFileDao.get("a")!!
        assertNull(row.thumbPath)
        assertEquals(1, row.thumbAttempts)
        assertEquals(listOf("a"), contentFileDao.thumbsToRetry(3).map { it.itemId })
        assertFalse(paths.thumbTemp("a").exists())

        thumbOk = true
        assertEquals(DownloadOutcome.AlreadyCurrent, store.download("a")) // downloads nothing but fixes the thumbnail
        row = contentFileDao.get("a")!!
        assertEquals(paths.thumb("a").absolutePath, row.thumbPath)
        assertTrue(paths.thumb("a").isFile)
        assertEquals(emptyList<String>(), contentFileDao.thumbsToRetry(3).map { it.itemId })
        assertFalse(paths.thumbTemp("a").exists())
    }

    @Test fun thumbnailLandingAfterTheItemIsGoneLeavesNothingBehind() = runBlocking {
        itemDao.upsertItem(entity("a", leadImageKey = "thumb.webp"))
        val gate = CompletableDeferred<Unit>()
        val api = StubApi(onDownload = { url, dest ->
            if (url.endsWith("thumb.webp")) gate.await()
            dest.writeBytes(if (url.endsWith("thumb.webp")) byteArrayOf(1) else TestPackages.packageBytes("<p>x</p>"))
            ApiResult.Success(Unit)
        })
        val store = storeWith(api)
        val job = async(Dispatchers.IO) { store.download("a") }
        withTimeout(5_000) { while (contentFileDao.get("a")?.state != ContentState.DOWNLOADED) delay(10) }
        // sign-out wipe happens while the thumbnail is still in flight
        db.maintenanceDao().wipeAll()
        paths.deleteAll()
        gate.complete(Unit)
        job.await()
        assertFalse(paths.thumb("a").exists())
        assertFalse(paths.thumbTemp("a").exists())
        assertEquals(0, store.storageUsageBytes())
    }

    @Test fun evictionHandlesMoreThanSqliteVariableLimit() = runBlocking {
        val old = now - 40L * 86_400_000
        for (i in 0 until 1_200) {
            val id = "e$i"
            itemDao.upsertItem(entity(id, status = ItemStatus.ARCHIVED, archivedAt = old))
            contentFileDao.upsert(ContentFileEntity(id, "c-$id", ContentState.DOWNLOADED))
        }
        contentStore.evict()
        assertEquals(0, contentFileDao.all().size)
    }

    @Test fun unsafeIdsNeverBecomePaths() = runBlocking {
        val sibling = tmp.newFile("files/sibling.txt").also { it.writeText("keep") }
        paths.deleteItemFiles("..")
        paths.deleteItemFiles("../x")
        paths.deleteItemFiles("a/b")
        assertTrue(sibling.exists())
        assertTrue(paths.articles.parentFile!!.exists())
        assertEquals(DownloadOutcome.Failed(RemoteFailure.SERVER), contentStore.download(".."))
        assertNull(contentStore.articleHtml("../x"))
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { paths.articleDir("..") }
        assertEquals(0, server.requestCount)
    }
}
