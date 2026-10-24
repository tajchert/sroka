package app.sroka.feature.reader.impl

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

    private fun vm() = ReaderViewModel(
        "a", library, content, FakeSettingsRepository(), FakeTagRepository(),
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
