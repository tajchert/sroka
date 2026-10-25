package app.sroka.core.data

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.Data
import androidx.work.WorkInfo
import androidx.work.testing.WorkManagerTestInitHelper
import app.sroka.core.data.content.ContentPaths
import app.sroka.core.data.upload.PdfThumbnail
import app.sroka.core.data.upload.PdfThumbnailRenderer
import app.sroka.core.data.upload.PdfUploadProcessor
import app.sroka.core.data.upload.PdfUploadWork
import app.sroka.core.data.upload.PdfUploaderImpl
import app.sroka.core.data.upload.UploadOutcome
import app.sroka.core.data.upload.pdfUploadOf
import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ContentState
import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.PdfFileResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.model.ItemKind
import app.sroka.core.model.MAX_PDF_BYTES
import app.sroka.core.model.OfflineState
import app.sroka.core.model.PdfUpload
import app.sroka.core.model.PdfUploadError
import app.sroka.core.model.PdfUploadState
import app.sroka.core.network.NetworkConfig
import app.sroka.core.network.SessionProvider
import app.sroka.core.network.SrokaApiFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

internal class PdfDataTest : DataTestBase() {

    private val pdfBytes = "%PDF-1.7\n%fake body\n".toByteArray()

    private val api by lazy {
        val provider = object : SessionProvider {
            override suspend fun token() = "tok"
            override suspend fun deviceId() = "and_test"
            override suspend fun baseUrl() = server.url("/").toString().trimEnd('/')
        }
        SrokaApiFactory.create(provider, NetworkConfig("Sroka-Android/test"))
    }

    private fun pdfUrls(base: String = server.url("/p/c/").toString()) =
        enqueueJson("""{"articleUrl":"${base}article.html","baseUrl":"$base","packageUrl":"${base}package.zip","documentUrl":"${base}document.pdf","expiresAt":1}""")

    // ---- sync mapping -----------------------------------------------------------------------

    @Test fun pullMapsPdfFieldsAndDefaultsOldItemsToArticle() = runBlocking {
        val pdf = """{"id":"p1","url":"https://sroka.app/pdf/abc","canonicalUrl":"https://sroka.app/pdf/abc","title":"Paper","parseStatus":"pending",""" +
            """"status":"unread","isFavorite":false,"progress":0,"savedAt":5,"tags":[],"seq":1,"contentId":"c1","contentPrivate":true,""" +
            """"kind":"pdf","fileName":"paper.pdf","fileSize":2048,"siteName":"PDF"}"""
        val future = itemJson("a2", 2).dropLast(1) + ""","kind":"hologram"}"""
        enqueueJson(pullJson(2, listOf(pdf, itemJson("a1", 3), future)))
        engine.sync()
        val p = itemDao.getItem("p1")!!
        assertEquals(ItemKind.PDF, p.kind)
        assertEquals("paper.pdf", p.fileName)
        assertEquals(2048L, p.fileSize)
        assertEquals(ItemKind.ARTICLE, itemDao.getItem("a1")!!.kind)
        assertEquals(ItemKind.ARTICLE, itemDao.getItem("a2")!!.kind)
        assertNull(itemDao.getItem("a1")!!.fileSize)
    }

    // ---- upload error mapping ---------------------------------------------------------------

    private fun uploadFile(bytes: ByteArray = pdfBytes) = tmp.newFile().apply { writeBytes(bytes) }

    private fun respond(code: Int, body: String = "") =
        server.enqueue(MockResponse.Builder().code(code).body(body).addHeader("Content-Type", "application/json").build())

    private suspend fun outcome(code: Int, body: String = ""): UploadOutcome {
        respond(code, body)
        return PdfUploadProcessor(api).upload(uploadFile(), "a.pdf", "share") { _, _ -> }
    }

    @Test fun successSendsRawBodyWithNameAndSource() = runBlocking {
        respond(202, """{"item":{"id":"srv1","url":"u","kind":"pdf"},"created":false}""")
        val progress = mutableListOf<Long>()
        val result = PdfUploadProcessor(api).upload(uploadFile(), "My paper.pdf", "share") { sent, _ -> progress += sent }
        assertEquals(UploadOutcome.Uploaded("srv1", duplicate = true), result)
        val req = takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/v1/items/pdf", req.url.encodedPath)
        assertEquals("My paper.pdf", req.url.queryParameter("name"))
        assertEquals("share", req.url.queryParameter("source"))
        assertEquals("application/pdf", req.headers["Content-Type"])
        assertEquals(pdfBytes.size.toString(), req.headers["Content-Length"])
        assertEquals(pdfBytes.size, req.body!!.size)
        assertEquals("Bearer tok", req.headers["Authorization"])
        assertTrue(progress.isNotEmpty() && progress.last() == pdfBytes.size.toLong())
    }

    // ---- first-page preview --------------------------------------------------------------

    private val preview = byteArrayOf(9, 8, 7)

    private class RecordingRenderer(private val bytes: ByteArray?) : PdfThumbnailRenderer {
        val rendered = mutableListOf<File>()
        override fun render(file: File): PdfThumbnail? {
            rendered += file
            return bytes?.let { PdfThumbnail(it, "image/webp") }
        }
    }

    @Test fun uploadsTheRenderedPreviewForAnItemWithoutOne() = runBlocking {
        respond(202, """{"item":{"id":"srv1","url":"u","kind":"pdf"},"created":true}""")
        respond(200, """{"item":{"id":"srv1","url":"u","kind":"pdf","leadImageKey":"thumb.webp"}}""")
        val renderer = RecordingRenderer(preview)
        val file = uploadFile()
        val result = PdfUploadProcessor(api, renderer).upload(file, "a.pdf", "share") { _, _ -> }
        assertEquals(UploadOutcome.Uploaded("srv1", duplicate = false), result)
        assertEquals(listOf(file), renderer.rendered)
        takeRequest()
        val put = takeRequest()
        assertEquals("PUT", put.method)
        assertEquals("/v1/items/srv1/thumbnail", put.url.encodedPath)
        assertEquals("image/webp", put.headers["Content-Type"])
        assertEquals(preview.size, put.body!!.size)
    }

    @Test fun skipsThePreviewWhenTheDuplicateAlreadyHasOne() = runBlocking {
        respond(202, """{"item":{"id":"srv1","url":"u","kind":"pdf","leadImageKey":"thumb.webp"},"created":false}""")
        val renderer = RecordingRenderer(preview)
        val result = PdfUploadProcessor(api, renderer).upload(uploadFile(), "a.pdf", "share") { _, _ -> }
        assertEquals(UploadOutcome.Uploaded("srv1", duplicate = true), result)
        assertTrue(renderer.rendered.isEmpty())
        assertEquals(1, server.requestCount)
    }

    @Test fun aFailedPreviewNeverFailsTheUpload() = runBlocking {
        // renderer gives nothing: no PUT
        respond(202, """{"item":{"id":"srv1","url":"u","kind":"pdf"},"created":true}""")
        assertEquals(UploadOutcome.Uploaded("srv1", duplicate = false), PdfUploadProcessor(api, RecordingRenderer(null)).upload(uploadFile(), "a.pdf", "share") { _, _ -> })
        assertEquals(1, server.requestCount)
        // PUT rejected: still uploaded
        respond(202, """{"item":{"id":"srv2","url":"u","kind":"pdf"},"created":true}""")
        respond(500)
        assertEquals(UploadOutcome.Uploaded("srv2", duplicate = false), PdfUploadProcessor(api, RecordingRenderer(preview)).upload(uploadFile(), "a.pdf", "share") { _, _ -> })
        assertEquals(3, server.requestCount)
    }

    @Test fun permanentErrors() = runBlocking {
        assertEquals(UploadOutcome.Permanent(PdfUploadError.TOO_LARGE), outcome(413, """{"error":"payload_too_large"}"""))
        assertEquals(UploadOutcome.Permanent(PdfUploadError.NOT_PDF), outcome(415, """{"error":"unsupported_media_type"}"""))
        assertEquals(UploadOutcome.Permanent(PdfUploadError.STORAGE_FULL), outcome(409, """{"error":"storage_full"}"""))
        assertEquals(UploadOutcome.Permanent(PdfUploadError.UNKNOWN), outcome(400, """{"error":"invalid_request"}"""))
        assertEquals(UploadOutcome.Permanent(PdfUploadError.UNKNOWN), outcome(411, """{"error":"length_required"}"""))
        // 409 with another code is not a quota problem.
        assertEquals(UploadOutcome.Permanent(PdfUploadError.UNKNOWN), outcome(409, """{"error":"conflict"}"""))
    }

    @Test fun transientErrors() = runBlocking {
        assertEquals(UploadOutcome.Transient(PdfUploadError.AUTH), outcome(401, """{"error":"unauthorized"}"""))
        assertEquals(UploadOutcome.Transient(PdfUploadError.UNKNOWN), outcome(500))
        assertEquals(UploadOutcome.Transient(PdfUploadError.UNKNOWN), outcome(503))
        assertEquals(UploadOutcome.Transient(PdfUploadError.UNKNOWN), outcome(429, """{"error":"rate_limited"}"""))
        server.close()
        assertEquals(UploadOutcome.Transient(PdfUploadError.NETWORK), PdfUploadProcessor(api).upload(uploadFile(), "a.pdf", "share") { _, _ -> })
    }

    @Test fun missingOrOversizedFileIsPermanentWithoutNetwork() = runBlocking {
        val processor = PdfUploadProcessor(api)
        assertEquals(UploadOutcome.Permanent(PdfUploadError.UNKNOWN), processor.upload(File(tmp.root, "gone.pdf"), "a.pdf", "share") { _, _ -> })
        val big = tmp.newFile().apply { java.io.RandomAccessFile(this, "rw").use { it.setLength(MAX_PDF_BYTES + 1) } }
        assertEquals(UploadOutcome.Permanent(PdfUploadError.TOO_LARGE), processor.upload(big, "a.pdf", "share") { _, _ -> })
        assertEquals(0, server.requestCount)
    }

    // ---- WorkInfo mapping -------------------------------------------------------------------

    private fun info(state: WorkInfo.State, out: Data = Data.EMPTY, progress: Data = Data.EMPTY) = WorkInfo(
        UUID.randomUUID(), state, setOf(
            PdfUploadWork.TAG, PdfUploadWork.TAG_ID + "u1", PdfUploadWork.TAG_NAME + "a b.pdf",
            PdfUploadWork.TAG_SIZE + "100", PdfUploadWork.TAG_AT + "7",
        ), out, progress,
    )

    @Test fun workInfoMapsToUploadStates() {
        fun state(i: WorkInfo) = pdfUploadOf(i)!!.second.state
        assertEquals(PdfUploadState.Queued, state(info(WorkInfo.State.ENQUEUED)))
        assertEquals(PdfUploadState.Uploading(0.25f), state(info(WorkInfo.State.RUNNING, progress = Data.Builder().putLong("sent", 25).putLong("total", 100).build())))
        assertEquals(PdfUploadState.Uploading(0f), state(info(WorkInfo.State.RUNNING)))
        assertEquals(PdfUploadState.Done("i1", true), state(info(WorkInfo.State.SUCCEEDED, Data.Builder().putString("itemId", "i1").putBoolean("duplicate", true).build())))
        assertEquals(PdfUploadState.Failed(PdfUploadError.NOT_PDF), state(info(WorkInfo.State.FAILED, Data.Builder().putString("error", "NOT_PDF").build())))
        assertEquals(PdfUploadState.Failed(PdfUploadError.UNKNOWN), state(info(WorkInfo.State.FAILED)))
        assertNull(pdfUploadOf(info(WorkInfo.State.CANCELLED)))
        val (at, upload) = pdfUploadOf(info(WorkInfo.State.ENQUEUED))!!
        assertEquals(7L, at)
        assertEquals(PdfUpload("u1", "a b.pdf", 100, PdfUploadState.Queued), upload)
    }

    // ---- enqueue (copy + client checks) -----------------------------------------------------

    private fun uploader(): PdfUploaderImpl {
        val context = ApplicationProvider.getApplicationContext<Context>()
        WorkManagerTestInitHelper.initializeTestWorkManager(context, Configuration.Builder().build())
        return PdfUploaderImpl(context, paths, clock, Dispatchers.IO)
    }

    @Test fun enqueueCopiesFileAndRejectsBadOnes() = runBlocking {
        val up = uploader()
        val good = tmp.newFile("good.pdf").apply { writeBytes(pdfBytes) }
        val text = tmp.newFile("note.txt").apply { writeText("hello") }
        val empty = tmp.newFile("empty.pdf")
        val missing = File(tmp.root, "missing.pdf")
        val result = up.enqueue(listOf(good, text, empty, missing).map { Uri.fromFile(it) })

        assertEquals(PdfUploadState.Queued, result[0].state)
        assertEquals("good.pdf", result[0].fileName)
        assertEquals(pdfBytes.size.toLong(), result[0].sizeBytes)
        assertEquals(PdfUploadState.Failed(PdfUploadError.NOT_PDF), result[1].state)
        assertEquals(PdfUploadState.Failed(PdfUploadError.NOT_PDF), result[2].state)
        assertEquals(PdfUploadState.Failed(PdfUploadError.UNKNOWN), result[3].state)

        val copy = paths.pdfUploadFile(result[0].id)
        assertTrue(copy.isFile)
        assertEquals(pdfBytes.toList(), copy.readBytes().toList())
        // Rejected files leave no temp copy behind.
        assertEquals(listOf(copy.name), paths.pdfUploads.list()!!.toList())

        val listed = up.uploads.first()
        assertEquals(4, listed.size)
        up.clearFinished()
        assertEquals(1, up.uploads.first().count { it.state == PdfUploadState.Queued || it.state is PdfUploadState.Uploading })

        up.cancel(result[0].id)
        assertFalse(copy.exists())
    }

    // ---- ContentStore: PDF path -------------------------------------------------------------

    @Test fun downloadsPdfIntoOfflineDirAndExposesFile() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF))
        assertNull(contentStore.pdfFile("p"))
        pdfUrls()
        enqueueBytes(pdfBytes)
        val result = contentStore.ensurePdfFile("p")
        val file = (result as PdfFileResult.Ready).file
        assertEquals(paths.pdfFile("p"), file)
        assertEquals(pdfBytes.toList(), file.readBytes().toList())

        assertEquals("/v1/items/p/content", takeRequest().url.encodedPath)
        val doc = takeRequest()
        assertEquals("/p/c/document.pdf", doc.url.encodedPath)
        assertNull(doc.headers["Authorization"])

        val row = contentFileDao.get("p")!!
        assertEquals(ContentState.DOWNLOADED, row.state)
        assertEquals(pdfBytes.size.toLong(), row.bytes)
        assertEquals(OfflineState.DOWNLOADED, contentStore.observeOffline("p").first())
        assertFalse(paths.pdfTemp("p").exists())
        assertTrue(contentStore.storageUsageBytes() > 0)
        // Cached: no further requests.
        assertEquals(PdfFileResult.Ready(file), contentStore.ensurePdfFile("p"))
        assertEquals(2, server.requestCount)
    }

    private val thumbBytes = byteArrayOf(0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4)

    @Test fun pdfDownloadAlsoFetchesItsPreview() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF, leadImageKey = "thumb.webp"))
        pdfUrls()
        enqueueBytes(pdfBytes)
        enqueueBytes(thumbBytes)
        assertTrue(contentStore.ensurePdfFile("p") is PdfFileResult.Ready)
        takeRequest()
        takeRequest()
        assertEquals("/p/c/thumb.webp", server.takeRequest(5, java.util.concurrent.TimeUnit.SECONDS)?.url?.encodedPath)
        val row = contentFileDao.get("p")!!
        assertEquals(ContentState.DOWNLOADED, row.state)
        assertEquals(paths.thumb("p").absolutePath, row.thumbPath)
        assertEquals(thumbBytes.toList(), paths.thumb("p").readBytes().toList())
    }

    @Test fun previewArrivingAfterThePdfIsFetchedOnTheNextPass() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF))
        pdfUrls()
        enqueueBytes(pdfBytes)
        contentStore.ensurePdfFile("p")
        assertNull(contentFileDao.get("p")!!.thumbPath)
        assertEquals(2, server.requestCount)

        itemDao.upsertItem(entity("p", kind = ItemKind.PDF, leadImageKey = "thumb.webp"))
        pdfUrls()
        enqueueBytes(thumbBytes)
        contentStore.download("p")
        assertEquals(paths.thumb("p").absolutePath, contentFileDao.get("p")!!.thumbPath)
        assertEquals(4, server.requestCount)
    }

    @Test fun aFailedPreviewKeepsThePdfDownloaded() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF, leadImageKey = "thumb.webp"))
        pdfUrls()
        enqueueBytes(pdfBytes)
        respond(500)
        assertTrue(contentStore.ensurePdfFile("p") is PdfFileResult.Ready)
        val row = contentFileDao.get("p")!!
        assertEquals(ContentState.DOWNLOADED, row.state)
        assertNull(row.thumbPath)
        assertEquals(1, row.thumbAttempts)
    }

    @Test fun expiredSignedUrlIsRefreshedOnce() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF))
        pdfUrls()
        respond(403)
        pdfUrls()
        enqueueBytes(pdfBytes)
        assertTrue(contentStore.ensurePdfFile("p") is PdfFileResult.Ready)
        assertEquals(listOf("/v1/items/p/content", "/p/c/document.pdf", "/v1/items/p/content", "/p/c/document.pdf"), (1..4).map { takeRequest().url.encodedPath })
    }

    @Test fun persistent403FailsWithoutLooping() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF))
        repeat(2) { pdfUrls(); respond(403) }
        assertEquals(PdfFileResult.Failed(RemoteFailure.SERVER), contentStore.ensurePdfFile("p"))
        assertEquals(ContentState.FAILED, contentFileDao.get("p")!!.state)
        assertEquals(4, server.requestCount)
        assertNull(contentStore.pdfFile("p"))
    }

    @Test fun nonPdfBytesAreRejectedAndNotInstalled() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF))
        pdfUrls()
        enqueueBytes("<html>error page</html>".toByteArray())
        assertEquals(PdfFileResult.Failed(RemoteFailure.SERVER), contentStore.ensurePdfFile("p"))
        assertFalse(paths.pdfFile("p").exists())
        assertFalse(paths.pdfTemp("p").exists())
        assertEquals(ContentState.FAILED, contentFileDao.get("p")!!.state)
    }

    @Test fun missingDocumentUrlFails() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF))
        val base = server.url("/p/c/").toString()
        enqueueJson("""{"articleUrl":"${base}article.html","baseUrl":"$base","packageUrl":"${base}package.zip","expiresAt":1}""")
        assertTrue(contentStore.downloadNow("p") is DownloadResult.Failed)
    }

    @Test fun notParsedIs409AndNetworkFailureKeepsNoRow() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF))
        respond(409, """{"error":"not_parsed"}""")
        assertEquals(PdfFileResult.NotReady, contentStore.ensurePdfFile("p"))
        assertNull(contentFileDao.get("p"))
    }

    @Test fun clearDownloadsRemovesPdfButNotPendingUploads() = runBlocking {
        itemDao.upsertItem(entity("p", kind = ItemKind.PDF))
        pdfUrls()
        enqueueBytes(pdfBytes)
        contentStore.ensurePdfFile("p")
        val pending = paths.pdfUploadFile("u1").apply { parentFile!!.mkdirs(); writeBytes(pdfBytes) }
        contentStore.clearDownloads()
        assertNull(contentStore.pdfFile("p"))
        assertTrue(pending.exists())
    }
}
