package app.sroka.feature.reader.impl

import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.testing.fake.FakeContentStore
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeTagRepository
import app.sroka.core.testing.testItem
import app.sroka.core.testing.util.MainDispatcherRule
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
class ReaderViewModelTest {
    private val dispatcher = UnconfinedTestDispatcher()

    @get:Rule
    val main = MainDispatcherRule(dispatcher)

    private val id = "item-1"
    private val library = FakeLibraryRepository()
    private val content = FakeContentStore()
    private var clock = 10_000L

    private fun vm(): ReaderViewModel {
        val vm = ReaderViewModel(id, library, content, FakeSettingsRepository(), FakeTagRepository(), CoroutineScope(dispatcher))
        vm.nowMillis = { clock }
        return vm
    }

    private fun ReaderViewModel.collect(scope: kotlinx.coroutines.CoroutineScope) {
        uiState.onEach { }.launchIn(scope)
        item.onEach { }.launchIn(scope)
    }

    private fun seed(
        offline: OfflineState = OfflineState.DOWNLOADED,
        parse: ParseStatus = ParseStatus.OK,
        contentId: String? = "c1",
        progress: Float = 0f,
    ) {
        library.items.value = listOf(
            testItem(id = id, offline = offline, parseStatus = parse, contentId = contentId, progress = progress),
        )
    }

    @Test
    fun downloadedItemIsReady() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>Hi</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        val state = vm.uiState.value
        assertTrue(state is ReaderUiState.Ready)
        assertEquals("<p>Hi</p>", (state as ReaderUiState.Ready).html)
        assertEquals("https://appassets.androidplatform.net/articles/$id/", state.baseUrl)
    }

    @Test
    fun notDownloadedAutoDownloadsThenReady() = runTest(dispatcher) {
        seed(offline = OfflineState.AVAILABLE_REMOTE)
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(listOf(id), content.downloadRequests)
        assertTrue(vm.uiState.value is ReaderUiState.Ready)
    }

    @Test
    fun offlineDownloadFailureShowsOfflineMessageAndRetryWorks() = runTest(dispatcher) {
        seed(offline = OfflineState.AVAILABLE_REMOTE)
        content.nextDownloadResult = DownloadResult.Failed(RemoteFailure.NETWORK)
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(ReaderUiState.NotDownloaded(NotDownloadedReason.OFFLINE), vm.uiState.value)
        content.nextDownloadResult = DownloadResult.Downloaded
        vm.retryDownload()
        assertTrue(vm.uiState.value is ReaderUiState.Ready)
        assertEquals(2, content.downloadRequests.size)
    }

    @Test
    fun downloadResultsMapToStates() = runTest(dispatcher) {
        seed(offline = OfflineState.AVAILABLE_REMOTE)
        content.nextDownloadResult = DownloadResult.NotReady
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(ReaderUiState.ParsePending, vm.uiState.value)
        content.nextDownloadResult = DownloadResult.Failed(RemoteFailure.UNAUTHORIZED)
        vm.retryDownload()
        assertEquals(ReaderUiState.NotDownloaded(NotDownloadedReason.SIGN_IN), vm.uiState.value)
        content.nextDownloadResult = DownloadResult.Failed(RemoteFailure.SERVER)
        vm.retryDownload()
        assertEquals(ReaderUiState.NotDownloaded(NotDownloadedReason.ERROR), vm.uiState.value)
    }

    @Test
    fun pendingAndFailedParse() = runTest(dispatcher) {
        seed(offline = OfflineState.NONE, parse = ParseStatus.PENDING, contentId = null)
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(ReaderUiState.ParsePending, vm.uiState.value)
        assertTrue(content.downloadRequests.isEmpty())
        seed(offline = OfflineState.NONE, parse = ParseStatus.FAILED, contentId = null)
        assertEquals(ReaderUiState.ParseFailed(null), vm.uiState.value)
    }

    @Test
    fun deletedItemIsMissing() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>x</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        vm.delete()
        assertEquals(ReaderUiState.Missing, vm.uiState.value)
    }

    @Test
    fun progressUpdatesDoNotReloadArticle() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>x</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        val before = vm.uiState.value
        vm.onProgress(ProgressReport(0.4f, 3))
        assertEquals(0.4f, library.items.value.single().progress)
        assertTrue(before === vm.uiState.value)
    }

    @Test
    fun progressSavesAreThrottledAndFlushed() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>x</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        vm.onProgress(ProgressReport(0.1f, 1)) // saved
        clock += 500
        vm.onProgress(ProgressReport(0.2f, 2)) // throttled
        clock += 500
        vm.onProgress(ProgressReport(0.3f, 3)) // throttled
        assertEquals(0.1f, library.items.value.single().progress)
        assertEquals(0.3f, vm.progress.value)
        clock += 1_500
        vm.onProgress(ProgressReport(0.5f, 5)) // interval elapsed
        assertEquals(0.5f, library.items.value.single().progress)
        clock += 100
        vm.onProgress(ProgressReport(0.6f, 6)) // throttled
        vm.flushProgress()
        val saved = library.items.value.single()
        assertEquals(0.6f, saved.progress)
        assertEquals(6, saved.progressAnchor)
        assertEquals(RestorePoint(6, 0.6f), vm.restorePoint())
    }

    @Test
    fun flushWithoutScrollingMarksLastRead() = runTest(dispatcher) {
        seed(progress = 0.25f)
        content.html.value = mapOf(id to "<p>x</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        vm.flushProgress()
        assertEquals(1_760_500_000_000L, library.items.value.single().lastReadAt)
        assertEquals(0.25f, library.items.value.single().progress)
    }

    @Test
    fun noProgressWrittenWhenNotReady() = runTest(dispatcher) {
        seed(offline = OfflineState.NONE, parse = ParseStatus.PENDING, contentId = null)
        val vm = vm().also { it.collect(backgroundScope) }
        vm.onProgress(ProgressReport(0.9f, 1))
        vm.flushProgress()
        assertEquals(0f, library.items.value.single().progress)
    }

    @Test
    fun actionsReachRepository() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>x</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        vm.toggleFavorite()
        assertTrue(library.items.value.single().isFavorite)
        var archived: Boolean? = null
        vm.toggleArchive { archived = it }
        assertEquals(true, archived)
        assertEquals(ItemStatus.ARCHIVED, library.items.value.single().status)
        vm.toggleArchive { archived = it }
        assertEquals(false, archived)
        vm.setTags(listOf("b", "a"))
        assertEquals(listOf("a", "b"), library.items.value.single().tags)
    }

    @Test
    fun failedDownloadDoesNotLoop() = runTest(dispatcher) {
        seed(offline = OfflineState.AVAILABLE_REMOTE)
        content.offline.value = mapOf(id to OfflineState.AVAILABLE_REMOTE)
        content.nextDownloadResult = DownloadResult.Failed(RemoteFailure.SERVER)
        content.downloadHook = {
            content.offline.value = mapOf(id to OfflineState.DOWNLOADING)
            content.offline.value = mapOf(id to OfflineState.FAILED)
        }
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(1, content.downloadRequests.size)
        assertEquals(ReaderUiState.NotDownloaded(NotDownloadedReason.ERROR), vm.uiState.value)
        vm.retryDownload()
        assertEquals(2, content.downloadRequests.size)
        assertEquals(ReaderUiState.NotDownloaded(NotDownloadedReason.ERROR), vm.uiState.value)
    }

    @Test
    fun clearingTheViewModelFlushesLastPosition() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>x</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        vm.onProgress(ProgressReport(0.1f, 1)) // saved
        clock += 500
        vm.onProgress(ProgressReport(0.7f, 7)) // throttled
        assertEquals(0.1f, library.items.value.single().progress)
        vm.onCleared()
        assertEquals(0.7f, library.items.value.single().progress)
    }
}
