package app.sroka.feature.reader.impl

import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.testing.fake.FakeContentStore
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncStatusRepository
import app.sroka.core.model.SyncPhase
import app.sroka.core.model.SyncStatus
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
    private val sync = FakeSyncStatusRepository()
    private val syncController = app.sroka.core.testing.fake.FakeSyncController()
    private var clock = 10_000L

    private fun vm(): ReaderViewModel {
        val vm = ReaderViewModel(id, library, content, FakeSettingsRepository(), FakeTagRepository(), sync, syncController, CoroutineScope(dispatcher))
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
    fun inFlightDownloadElsewhereIsJoinedNotAwaitedForever() = runTest(dispatcher) {
        seed(offline = OfflineState.DOWNLOADING)
        content.offline.value = mapOf(id to OfflineState.DOWNLOADING)
        content.nextDownloadResult = DownloadResult.Downloaded
        content.downloadHook = { content.html.value = mapOf(id to "<p>x</p>") }
        val vm = vm().also { it.collect(backgroundScope) }
        assertEquals(1, content.downloadRequests.size)
        assertTrue(vm.uiState.value is ReaderUiState.Ready)
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

    private fun ReaderViewModel.collectEvents(into: MutableList<ReaderEvent>, scope: CoroutineScope) {
        events.onEach { into += it }.launchIn(scope)
        refreshing.onEach { }.launchIn(scope)
        offline.onEach { }.launchIn(scope)
    }

    private fun setParse(status: ParseStatus) {
        library.items.value = library.items.value.map { it.copy(parseStatus = status) }
    }

    private fun refreshCycle(result: ParseStatus) = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>Hi</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        val events = mutableListOf<ReaderEvent>()
        vm.collectEvents(events, backgroundScope)
        assertEquals(false, vm.refreshing.value)
        vm.refresh() // fake repository sets PENDING
        assertEquals(true, vm.refreshing.value)
        assertTrue(events.isEmpty())
        setParse(result)
        assertEquals(false, vm.refreshing.value)
        assertEquals(listOf<ReaderEvent>(ReaderEvent.RefreshSettled(result)), events)
        // No further events when the status changes without a user refresh.
        setParse(ParseStatus.PENDING)
        setParse(result)
        assertEquals(1, events.size)
    }

    @Test fun refreshSettlesOk() = refreshCycle(ParseStatus.OK)

    @Test fun refreshSettlesPartial() = refreshCycle(ParseStatus.PARTIAL)

    @Test fun refreshSettlesFailed() = refreshCycle(ParseStatus.FAILED)

    @Test
    fun refreshOnAlreadyPendingItemSettles() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>Hi</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        val events = mutableListOf<ReaderEvent>()
        vm.collectEvents(events, backgroundScope)
        setParse(ParseStatus.PENDING)
        vm.refresh()
        assertEquals(true, vm.refreshing.value)
        setParse(ParseStatus.OK)
        assertEquals(false, vm.refreshing.value)
        assertEquals(listOf<ReaderEvent>(ReaderEvent.RefreshSettled(ParseStatus.OK)), events)
    }

    @Test
    fun refreshRequestsSyncPeriodicallyUntilSettled() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>Hi</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        vm.collectEvents(mutableListOf(), backgroundScope)
        vm.refresh()
        assertEquals(0, syncController.syncRequests)
        dispatcher.scheduler.advanceTimeBy(8_100)
        assertEquals(2, syncController.syncRequests)
        setParse(ParseStatus.OK)
        dispatcher.scheduler.advanceTimeBy(20_000)
        assertEquals(2, syncController.syncRequests)
    }

    @Test
    fun refreshIsIgnoredOffline() = runTest(dispatcher) {
        seed()
        content.html.value = mapOf(id to "<p>Hi</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        vm.collectEvents(mutableListOf(), backgroundScope)
        sync.statusFlow.value = SyncStatus(phase = SyncPhase.Offline)
        assertEquals(true, vm.offline.value)
        vm.refresh()
        assertEquals(false, vm.refreshing.value)
        assertEquals(ParseStatus.OK, library.items.value.single().parseStatus)
    }

    @Test
    fun resumedProgressAnnouncedOnceAndStartOverResets() = runTest(dispatcher) {
        seed(progress = 0.42f)
        content.html.value = mapOf(id to "<p>Hi</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        val events = mutableListOf<ReaderEvent>()
        vm.collectEvents(events, backgroundScope)
        vm.onArticleShown()
        vm.onArticleShown()
        assertEquals(listOf<ReaderEvent>(ReaderEvent.ResumedFromProgress(0.42f)), events)
        vm.startOver()
        assertEquals(0f, vm.progress.value, 0f)
        assertEquals(0f, library.items.value.single().progress, 0f)
        assertEquals(0f, vm.restorePoint().progress, 0f)
    }

    @Test
    fun nearTopProgressIsNotAnnounced() = runTest(dispatcher) {
        seed(progress = 0.01f)
        content.html.value = mapOf(id to "<p>Hi</p>")
        val vm = vm().also { it.collect(backgroundScope) }
        val events = mutableListOf<ReaderEvent>()
        vm.collectEvents(events, backgroundScope)
        vm.onArticleShown()
        assertTrue(events.isEmpty())
    }
}
