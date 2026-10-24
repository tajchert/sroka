package app.sroka.feature.reader.impl

import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.model.OfflineState
import app.sroka.core.testing.fake.FakeContentStore
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.fake.FakeSyncStatusRepository
import app.sroka.core.testing.fake.FakeTagRepository
import app.sroka.core.testing.testPdfItem
import app.sroka.core.testing.util.MainDispatcherRule
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PdfReaderTest {
    private val dispatcher = UnconfinedTestDispatcher()

    @get:Rule
    val main = MainDispatcherRule(dispatcher)

    private val item = testPdfItem(offline = OfflineState.AVAILABLE_REMOTE)
    private val id = item.id
    private val library = FakeLibraryRepository().also { it.items.value = listOf(item) }
    private val content = FakeContentStore()
    private var clock = 10_000L
    private val file = File.createTempFile("paper", ".pdf").also { it.deleteOnExit() }

    private fun vm(): ReaderViewModel {
        val vm = ReaderViewModel(
            id, library, content, FakeSettingsRepository(), FakeTagRepository(), FakeSyncStatusRepository(),
            FakeSyncController(), CoroutineScope(dispatcher),
        )
        vm.nowMillis = { clock }
        return vm
    }

    private fun ReaderViewModel.collect(scope: CoroutineScope) {
        uiState.onEach { }.launchIn(scope)
        item.onEach { }.launchIn(scope)
    }

    @Test
    fun localFileOpensWithoutDownloading() = runTest(dispatcher) {
        content.pdfFiles.value = mapOf(id to file)
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(ReaderUiState.PdfReady(file), vm.uiState.value)
        assertTrue(content.downloadRequests.isEmpty())
    }

    @Test
    fun missingFileDownloadsThenOpens() = runTest(dispatcher) {
        content.downloadHook = { content.pdfFiles.value = mapOf(id to file) }
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(listOf(id), content.downloadRequests)
        assertEquals(ReaderUiState.PdfReady(file), vm.uiState.value)
    }

    @Test
    fun downloadFailuresAreTypedAndRetryWorks() = runTest(dispatcher) {
        content.nextDownloadResult = DownloadResult.Failed(RemoteFailure.NETWORK)
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(ReaderUiState.NotDownloaded(NotDownloadedReason.OFFLINE), vm.uiState.value)
        content.nextDownloadResult = DownloadResult.Failed(RemoteFailure.UNAUTHORIZED)
        vm.retryDownload()
        assertEquals(ReaderUiState.NotDownloaded(NotDownloadedReason.SIGN_IN), vm.uiState.value)
        content.nextDownloadResult = DownloadResult.Downloaded
        content.downloadHook = { content.pdfFiles.value = mapOf(id to file) }
        vm.retryDownload()
        assertEquals(ReaderUiState.PdfReady(file), vm.uiState.value)
    }

    @Test
    fun noDocumentYetIsPending() = runTest(dispatcher) {
        content.nextDownloadResult = DownloadResult.NotReady
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(ReaderUiState.ParsePending, vm.uiState.value)
    }

    @Test
    fun pageChangesWriteProgressAndAnchor() = runTest(dispatcher) {
        content.pdfFiles.value = mapOf(id to file)
        val vm = vm().also { it.collect(backgroundScope) }
        vm.onPdfPage(page = 2, pageCount = 10)
        assertEquals(0.3f, vm.progress.value, 0.0001f)
        val saved = library.items.value.single()
        assertEquals(0.3f, saved.progress, 0.0001f)
        assertEquals(2, saved.progressAnchor)
        assertEquals(2, vm.restorePoint().anchor)
    }

    @Test
    fun savedAnchorIsTheRestorePoint() = runTest(dispatcher) {
        library.items.value = listOf(item.copy(progress = 0.5f, progressAnchor = 4))
        content.pdfFiles.value = mapOf(id to file)
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(4, vm.restorePoint().anchor)
    }

    @Test
    fun lastPageReadsComplete() {
        assertEquals(1f, pdfProgress(9, 10), 0f)
        assertEquals(0.1f, pdfProgress(0, 10), 0.0001f)
        assertEquals(0f, pdfProgress(0, 0), 0f)
    }
}
