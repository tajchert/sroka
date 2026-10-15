package app.sroka.core.data

import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ContentState
import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.OfflineState
import kotlinx.coroutines.flow.first
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
}
