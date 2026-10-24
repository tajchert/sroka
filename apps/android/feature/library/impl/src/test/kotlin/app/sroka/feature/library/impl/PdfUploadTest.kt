package app.sroka.feature.library.impl

import android.net.Uri
import app.cash.turbine.test
import app.sroka.core.model.PdfUpload
import app.sroka.core.model.PdfUploadError
import app.sroka.core.model.PdfUploadState
import app.sroka.core.model.SessionState
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakePdfUploader
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.fake.FakeSyncStatusRepository
import app.sroka.core.testing.fake.FakeTagRepository
import app.sroka.core.testing.util.MainDispatcherRule
import app.sroka.feature.library.impl.list.DroppedItem
import app.sroka.feature.library.impl.list.LibraryListViewModel
import app.sroka.feature.library.impl.list.ListEvent
import app.sroka.feature.library.impl.list.UploadCard
import app.sroka.feature.library.impl.list.extractDroppedPdfUris
import app.sroka.feature.library.impl.list.formatFileSize
import app.sroka.feature.library.impl.list.selectUploadCards
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PdfUploadTest {
    @get:Rule
    val main = MainDispatcherRule()

    private val uploader = FakePdfUploader()
    private fun vm() = LibraryListViewModel(
        FakeLibraryRepository(), FakeTagRepository(), FakeSyncController(), FakeSyncStatusRepository(),
        FakeAuthRepository(SessionState.SignedIn("a@b.c")), FakeSettingsRepository(), uploader,
    )

    private fun upload(id: String, state: PdfUploadState, size: Long = 1_000) = PdfUpload(id, "$id.pdf", size, state)

    @Test
    fun cardsAreEmptyWithoutActiveOrFailedUploads() {
        assertEquals(emptyList<UploadCard>(), selectUploadCards(emptyList()))
        assertEquals(emptyList<UploadCard>(), selectUploadCards(listOf(upload("a", PdfUploadState.Done("i", false)))))
    }

    @Test
    fun queuedUploadsAreIndeterminateAndStartedOnesWeightBySize() {
        val queued = selectUploadCards(listOf(upload("a", PdfUploadState.Queued), upload("b", PdfUploadState.Queued)))
        assertEquals(listOf<UploadCard>(UploadCard.Uploading(2, null)), queued)
        val mixed = selectUploadCards(
            listOf(upload("a", PdfUploadState.Uploading(0.5f), 3_000), upload("b", PdfUploadState.Queued, 1_000)),
        )
        val card = mixed.single() as UploadCard.Uploading
        assertEquals(2, card.count)
        assertEquals(0.375f, card.fraction!!, 0.0001f)
    }

    @Test
    fun failedCardNamesTheFirstFailureAndCountsTheRest() {
        val cards = selectUploadCards(
            listOf(
                upload("a", PdfUploadState.Uploading(0.1f)),
                upload("b", PdfUploadState.Failed(PdfUploadError.TOO_LARGE)),
                upload("c", PdfUploadState.Failed(PdfUploadError.NETWORK)),
            ),
        )
        assertEquals(2, cards.size)
        val failed = cards[1] as UploadCard.Failed
        assertEquals("b.pdf", failed.fileName)
        assertEquals(1, failed.more)
        assertTrue(!failed.canRetry)
        assertTrue(UploadCard.Failed("x", PdfUploadError.NETWORK, 0).canRetry)
    }

    @Test
    fun fileSizeFormatting() {
        java.util.Locale.setDefault(java.util.Locale.US)
        assertEquals("2.4 MB", formatFileSize(2_411_724))
        assertEquals("840 KB", formatFileSize(840_000))
        assertEquals("12 B", formatFileSize(12))
    }

    @Test
    fun addPdfsEnqueuesAndAnnouncesQueuedCount() = runTest {
        val vm = vm()
        vm.events.test {
            vm.addPdfs(listOf(Uri.parse("content://x/1"), Uri.parse("content://x/2")))
            assertEquals(ListEvent.PdfQueued(2), awaitItem())
        }
        assertEquals(1, uploader.enqueued.size)
    }

    @Test
    fun rejectedFilesAreAnnouncedAsFailuresNotAsQueued() = runTest {
        val vm = vm()
        uploader.nextError = PdfUploadError.NOT_PDF
        vm.uploadEvents.test {
            vm.addPdfs(listOf(Uri.parse("content://x/1")))
            assertEquals(ListEvent.PdfFailed(PdfUploadError.NOT_PDF), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun doneIsAnnouncedOnceAndForgotten() = runTest {
        val vm = vm()
        uploader.enqueue(listOf(Uri.parse("content://x/1")))
        vm.uploadEvents.test {
            uploader.complete("upload-1", duplicate = true)
            assertEquals(ListEvent.PdfDone(duplicate = true, itemId = "item-upload-1"), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
        assertEquals(1, uploader.clearedFinished)
    }

    @Test
    fun failuresStayUntilDismissed() = runTest {
        val vm = vm()
        uploader.nextError = PdfUploadError.TOO_LARGE
        uploader.enqueue(listOf(Uri.parse("content://x/1")))
        vm.uploadEvents.test {
            assertEquals(ListEvent.PdfFailed(PdfUploadError.TOO_LARGE), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
        assertEquals(0, uploader.clearedFinished)
        vm.dismissUploadFailures()
        assertEquals(1, uploader.clearedFinished)
        assertNull(uploader.state.value.firstOrNull())
    }

    @Test
    fun droppedPdfUrisNeedAPdfClip() {
        val items = listOf(DroppedItem(documentUri = "content://a/1"), DroppedItem(documentUri = "content://a/1"), DroppedItem(text = "hi"))
        assertEquals(listOf("content://a/1"), extractDroppedPdfUris(items, clipIsPdf = true))
        assertEquals(emptyList<String>(), extractDroppedPdfUris(items, clipIsPdf = false))
    }
}
