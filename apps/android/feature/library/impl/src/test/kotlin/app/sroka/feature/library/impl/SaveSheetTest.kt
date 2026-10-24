package app.sroka.feature.library.impl

import app.sroka.core.model.SessionState
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakeTagRepository
import app.sroka.core.testing.testItem
import app.sroka.core.testing.util.MainDispatcherRule
import app.sroka.feature.library.impl.save.SaveSheetViewModel
import app.sroka.feature.library.impl.save.SaveState
import app.sroka.feature.library.impl.save.readProgressOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SaveSheetTest {

    private val dispatcher = UnconfinedTestDispatcher()

    @get:Rule
    val main = MainDispatcherRule(dispatcher)

    private val library = FakeLibraryRepository()

    private fun vm() = SaveSheetViewModel(library, FakeTagRepository(), FakeAuthRepository(SessionState.SignedIn("a@b.c")))

    private fun SaveSheetViewModel.keepItemHot() = item.onEach { }.launchIn(CoroutineScope(dispatcher))

    @Test
    fun readProgressTextNumbers() {
        val item = testItem(progress = 0.42f).copy(readingMinutes = 10)
        val rp = readProgressOf(item)
        assertEquals(42, rp.percent)
        assertEquals(6, rp.minutesLeft)
        assertNull(readProgressOf(testItem(progress = 0f).copy(readingMinutes = null)).minutesLeft)
    }

    @Test
    fun alreadySavedItemIsObservedWithProgress() {
        library.items.value = listOf(testItem(id = "a", url = "https://example.com/a", progress = 0.5f))
        val vm = vm()
        val job = vm.keepItemHot()
        vm.start("https://example.com/a", null)
        assertTrue((vm.state.value as SaveState.Saved).alreadySaved)
        assertEquals(0.5f, vm.item.value?.progress)
        job.cancel()
    }

    @Test
    fun favouriteToggles() {
        val vm = vm()
        val job = vm.keepItemHot()
        vm.start("https://example.com/x", null)
        assertFalse(vm.item.value!!.isFavorite)
        vm.toggleFavorite()
        assertTrue(vm.item.value!!.isFavorite)
        vm.toggleFavorite()
        assertFalse(vm.item.value!!.isFavorite)
        job.cancel()
    }

    @Test
    fun autoDismissesAfterFourSeconds() {
        val vm = vm()
        vm.start("https://example.com/x", null)
        dispatcher.scheduler.advanceTimeBy(3_900)
        dispatcher.scheduler.runCurrent()
        assertFalse(vm.autoDismissed.value)
        dispatcher.scheduler.advanceTimeBy(200)
        dispatcher.scheduler.runCurrent()
        assertTrue(vm.autoDismissed.value)
    }

    @Test
    fun interactionCancelsAutoDismiss() {
        val vm = vm()
        vm.start("https://example.com/x", null)
        dispatcher.scheduler.advanceTimeBy(2_000)
        vm.onInteraction()
        dispatcher.scheduler.advanceTimeBy(10_000)
        dispatcher.scheduler.runCurrent()
        assertFalse(vm.autoDismissed.value)
    }
}
