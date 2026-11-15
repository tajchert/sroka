package app.sroka.feature.reader.impl

import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.ReaderFont
import app.sroka.core.model.ReaderLineSpacing
import app.sroka.core.testing.fake.FakeContentStore
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.fake.FakeSyncStatusRepository
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
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ReaderUpNextTest {
    private val dispatcher = UnconfinedTestDispatcher()

    @get:Rule
    val main = MainDispatcherRule(dispatcher)

    private val library = FakeLibraryRepository()

    private val content = FakeContentStore()
    private val settings = FakeSettingsRepository()

    private fun vm() = ReaderViewModel(
        "a", library, content, settings, FakeTagRepository(),
        FakeSyncStatusRepository(), FakeSyncController(), CoroutineScope(dispatcher),
    )

    @Test
    fun upNextIsNewestUnreadOtherThanThisOne() = runTest(dispatcher) {
        library.items.value = listOf(testItem(id = "a", savedAt = 2_000L), testItem(id = "b", savedAt = 1_000L))
        val vm = vm()
        vm.upNext.onEach { }.launchIn(backgroundScope)
        // The newest unread is the open item itself: the card shows the next one instead.
        assertEquals("b", vm.upNext.value?.id)
        library.items.value = listOf(testItem(id = "a", savedAt = 2_000L))
        assertEquals(null, vm.upNext.value)
        library.items.value = listOf(testItem(id = "a", savedAt = 1_000L), testItem(id = "b", savedAt = 2_000L))
        assertEquals("b", vm.upNext.value?.id)
    }

    @Test
    fun endNextOnlyOffersItemsThatOpenAsReadable() = runTest(dispatcher) {
        val open = testItem(id = "a", savedAt = 1_000L)
        library.items.value = listOf(open, testItem(id = "p", savedAt = 5_000L, parseStatus = ParseStatus.PENDING))
        val vm = vm()
        vm.upNext.onEach { }.launchIn(backgroundScope)
        vm.endNext.onEach { }.launchIn(backgroundScope)
        assertEquals("p", vm.upNext.value?.id) // the tabletop card keeps its rule
        assertEquals(null, vm.endNext.value) // a pending article would open an empty reader
        library.items.value = listOf(open, testItem(id = "f", savedAt = 5_000L, parseStatus = ParseStatus.FAILED))
        assertEquals(null, vm.endNext.value)
        library.items.value = listOf(open, testItem(id = "ok", savedAt = 5_000L, parseStatus = ParseStatus.OK))
        assertEquals("ok", vm.endNext.value?.id)
        library.items.value = listOf(open, testItem(id = "part", savedAt = 5_000L, parseStatus = ParseStatus.PARTIAL))
        assertEquals("part", vm.endNext.value?.id)
        // A PDF opens at once, even while the server still parses it.
        library.items.value = listOf(open, testItem(id = "pdf", savedAt = 5_000L, kind = ItemKind.PDF, parseStatus = ParseStatus.PENDING))
        assertEquals("pdf", vm.endNext.value?.id)
        // Archived items are not "next".
        library.items.value = listOf(open, testItem(id = "done", savedAt = 5_000L, status = ItemStatus.ARCHIVED))
        assertEquals(null, vm.endNext.value)
    }

    @Test
    fun archiveAndNextArchivesThenOpensTheNextItem() = runTest(dispatcher) {
        library.items.value = listOf(testItem(id = "a", savedAt = 2_000L), testItem(id = "b", savedAt = 1_000L))
        val vm = vm()
        vm.endNext.onEach { }.launchIn(backgroundScope)
        var opened: String? = null
        var noNext = false
        vm.archiveAndNext(onNext = { opened = it }, onNoNext = { noNext = true })
        assertEquals("b", opened)
        assertEquals(false, noNext)
        assertEquals(ItemStatus.ARCHIVED, library.items.value.first { it.id == "a" }.status)
        assertEquals(ItemStatus.UNREAD, library.items.value.first { it.id == "b" }.status)
    }

    @Test
    fun archiveAndNextWithoutNextBehavesLikeArchive() = runTest(dispatcher) {
        library.items.value = listOf(testItem(id = "a"))
        val vm = vm()
        vm.endNext.onEach { }.launchIn(backgroundScope)
        var opened: String? = null
        var noNext = false
        vm.archiveAndNext(onNext = { opened = it }, onNoNext = { noNext = true })
        assertEquals(null, opened)
        assertEquals(true, noNext)
        assertEquals(ItemStatus.ARCHIVED, library.items.value.single().status)
    }

    @Test
    fun atEndFollowsTheReaderScriptAndResetsOnStartOver() = runTest(dispatcher) {
        library.items.value = listOf(testItem(id = "a"))
        content.html.value = mapOf("a" to "<p>Hi</p>")
        val vm = vm()
        vm.uiState.onEach { }.launchIn(backgroundScope)
        vm.item.onEach { }.launchIn(backgroundScope)
        assertEquals(false, vm.atEnd.value)
        vm.onProgress(ProgressReport(1f, 4, atEnd = true))
        assertEquals(true, vm.atEnd.value)
        vm.onProgress(ProgressReport(0.9f, 3, atEnd = false))
        assertEquals(false, vm.atEnd.value)
        vm.onProgress(ProgressReport(1f, 4, atEnd = true))
        vm.startOver()
        assertEquals(false, vm.atEnd.value)
    }

    @Test
    fun fontAndSpacingPersistThroughSettings() = runTest(dispatcher) {
        val vm = vm()
        vm.preferences.onEach { }.launchIn(backgroundScope)
        assertEquals(ReaderFont.SANS, vm.preferences.value.readerFont)
        assertEquals(ReaderLineSpacing.NORMAL, vm.preferences.value.readerLineSpacing)
        vm.setReaderFont(ReaderFont.SERIF)
        vm.setReaderLineSpacing(ReaderLineSpacing.TIGHT)
        assertEquals(ReaderFont.SERIF, vm.preferences.value.readerFont)
        assertEquals(ReaderLineSpacing.TIGHT, vm.preferences.value.readerLineSpacing)
    }

    @Test
    fun scrubUpdatesProgress() = runTest(dispatcher) {
        library.items.value = listOf(testItem(id = "a"))
        content.html.value = mapOf("a" to "<p>Hi</p>")
        val vm = vm()
        vm.uiState.onEach { }.launchIn(backgroundScope)
        vm.item.onEach { }.launchIn(backgroundScope)
        vm.onScrub(0.5f)
        assertEquals(0.5f, vm.progress.value, 0f)
        assertEquals(0.5f, vm.restorePoint().progress, 0f)
    }
}
