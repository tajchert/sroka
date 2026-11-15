package app.sroka.feature.library.impl

import androidx.compose.material3.SwipeToDismissBoxValue
import app.cash.turbine.test
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.SessionState
import app.sroka.core.model.SwipeAction
import app.sroka.core.model.UserPreferences
import app.sroka.core.model.toSummary
import app.sroka.core.testing.fake.FakeAccountRepository
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakePdfUploader
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.fake.FakeSyncStatusRepository
import app.sroka.core.testing.fake.FakeTagRepository
import app.sroka.core.testing.testItem
import app.sroka.core.testing.util.MainDispatcherRule
import app.sroka.feature.library.impl.list.LibraryListViewModel
import app.sroka.feature.library.impl.list.ListEvent
import app.sroka.feature.library.impl.list.SwipeConfig
import app.sroka.feature.library.impl.list.SwipeSide
import app.sroka.feature.library.impl.list.peekSide
import app.sroka.feature.library.impl.list.toDirection
import app.sroka.feature.library.impl.list.toSide
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class SwipeActionsTest {

    @get:Rule
    val main = MainDispatcherRule()

    private val library = FakeLibraryRepository()

    private fun vm(settings: FakeSettingsRepository = FakeSettingsRepository()) = LibraryListViewModel(
        library, FakeTagRepository(), FakeAccountRepository(), FakeSyncController(), FakeSyncStatusRepository(),
        FakeAuthRepository(SessionState.SignedIn("a@b.c")), settings, FakePdfUploader(),
    )

    private fun settings(left: SwipeAction, right: SwipeAction, hintShown: Boolean = true) =
        FakeSettingsRepository(UserPreferences(swipeLeftAction = left, swipeRightAction = right, swipeHintShown = hintShown))

    private val item get() = library.items.value.single()

    @Test
    fun defaultsAreTheOriginalBehaviour() = runTest {
        library.items.value = listOf(testItem(id = "a"))
        val vm = vm()
        assertEquals(SwipeAction.ARCHIVE, vm.swipeConfig.value.left)
        assertEquals(SwipeAction.NONE, vm.swipeConfig.value.right)
        // Right is off by default: nothing happens.
        assertEquals(SwipeAction.NONE, vm.swipe(SwipeSide.RIGHT, item.toSummary()))
        assertEquals(ItemStatus.UNREAD, item.status)
        assertFalse(item.isFavorite)
        // Left archives, with an undo event.
        vm.events.test {
            assertEquals(SwipeAction.ARCHIVE, vm.swipe(SwipeSide.LEFT, item.toSummary()))
            assertTrue(awaitItem() is ListEvent.Undoable)
        }
        assertEquals(ItemStatus.ARCHIVED, item.status)
    }

    @Test
    fun archiveActionOnBothSidesAndUnarchivesInTheArchive() = runTest {
        library.items.value = listOf(testItem(id = "a"))
        val vm = vm(settings(SwipeAction.NONE, SwipeAction.ARCHIVE))
        vm.events.test {
            assertEquals(SwipeAction.NONE, vm.swipe(SwipeSide.LEFT, item.toSummary()))
            assertEquals(ItemStatus.UNREAD, item.status)
            assertEquals(SwipeAction.ARCHIVE, vm.swipe(SwipeSide.RIGHT, item.toSummary()))
            assertTrue(awaitItem() is ListEvent.Undoable)
            assertEquals(ItemStatus.ARCHIVED, item.status)
            // Archived rows move back to My List.
            vm.swipe(SwipeSide.RIGHT, item.toSummary())
            assertTrue(awaitItem() is ListEvent.Undoable)
        }
        assertEquals(ItemStatus.UNREAD, item.status)
    }

    @Test
    fun favoriteTogglesInEitherDirectionWithUndo() = runTest {
        library.items.value = listOf(testItem(id = "a"))
        for (side in SwipeSide.entries) {
            val vm = vm(if (side == SwipeSide.LEFT) settings(SwipeAction.FAVORITE, SwipeAction.NONE) else settings(SwipeAction.NONE, SwipeAction.FAVORITE))
            vm.events.test {
                assertEquals(SwipeAction.FAVORITE, vm.swipe(side, item.toSummary()))
                val added = awaitItem() as ListEvent.Undoable
                assertTrue(item.isFavorite)
                assertEquals(ItemStatus.UNREAD, item.status)
                vm.undo(added.undo)
                testScheduler.advanceUntilIdle()
                assertFalse(item.isFavorite)
                // Swiping a favorite removes it.
                library.items.value = listOf(item.copy(isFavorite = true))
                vm.swipe(side, item.toSummary())
                awaitItem()
                assertFalse(item.isFavorite)
            }
        }
    }

    @Test
    fun tagsActionOnlyAsksTheScreenToOpenTheEditor() = runTest {
        library.items.value = listOf(testItem(id = "a", tags = listOf("x")))
        for (side in SwipeSide.entries) {
            val vm = vm(if (side == SwipeSide.LEFT) settings(SwipeAction.TAGS, SwipeAction.NONE) else settings(SwipeAction.NONE, SwipeAction.TAGS))
            vm.events.test {
                assertEquals(SwipeAction.TAGS, vm.swipe(side, item.toSummary()))
                expectNoEvents()
            }
            assertEquals(ItemStatus.UNREAD, item.status)
            assertFalse(item.isFavorite)
            assertEquals(listOf("x"), item.tags)
        }
    }

    @Test
    fun noneDoesNothing() = runTest {
        library.items.value = listOf(testItem(id = "a"))
        val vm = vm(settings(SwipeAction.NONE, SwipeAction.NONE))
        vm.events.test {
            assertEquals(SwipeAction.NONE, vm.swipe(SwipeSide.LEFT, item.toSummary()))
            assertEquals(SwipeAction.NONE, vm.swipe(SwipeSide.RIGHT, item.toSummary()))
            expectNoEvents()
        }
        assertEquals(ItemStatus.UNREAD, item.status)
        assertFalse(item.isFavorite)
    }

    @Test
    fun configFollowsSettingsLive() = runTest {
        val repo = FakeSettingsRepository()
        val vm = vm(repo)
        repo.setSwipeRightAction(SwipeAction.FAVORITE)
        repo.setSwipeLeftAction(SwipeAction.TAGS)
        assertEquals(SwipeConfig(SwipeAction.TAGS, SwipeAction.FAVORITE, hintShown = false), vm.swipeConfig.value)
    }

    @Test
    fun hintFlagIsStoredOnceMarked() = runTest {
        val repo = FakeSettingsRepository()
        val vm = vm(repo)
        assertFalse(vm.swipeConfig.value.hintShown)
        vm.markSwipeHintShown()
        assertTrue(repo.preferencesFlow.value.swipeHintShown)
        assertTrue(vm.swipeConfig.value.hintShown)
    }

    @Test
    fun peekSideNeedsAnUnseenHintAndAnAction() {
        assertEquals(SwipeSide.LEFT, SwipeConfig(SwipeAction.ARCHIVE, SwipeAction.NONE, hintShown = false).peekSide())
        assertEquals(SwipeSide.RIGHT, SwipeConfig(SwipeAction.NONE, SwipeAction.TAGS, hintShown = false).peekSide())
        assertEquals(SwipeSide.LEFT, SwipeConfig(SwipeAction.FAVORITE, SwipeAction.TAGS, hintShown = false).peekSide())
        assertNull(SwipeConfig(SwipeAction.NONE, SwipeAction.NONE, hintShown = false).peekSide())
        assertNull(SwipeConfig(SwipeAction.ARCHIVE, SwipeAction.NONE, hintShown = true).peekSide())
        // The default config (screenshots, previews) never peeks.
        assertNull(SwipeConfig().peekSide())
    }

    @Test
    fun physicalSidesMapToLayoutDirections() {
        assertEquals(SwipeToDismissBoxValue.EndToStart, SwipeSide.LEFT.toDirection(rtl = false))
        assertEquals(SwipeToDismissBoxValue.StartToEnd, SwipeSide.RIGHT.toDirection(rtl = false))
        assertEquals(SwipeToDismissBoxValue.StartToEnd, SwipeSide.LEFT.toDirection(rtl = true))
        assertEquals(SwipeToDismissBoxValue.EndToStart, SwipeSide.RIGHT.toDirection(rtl = true))
        for (rtl in listOf(false, true)) for (side in SwipeSide.entries) {
            assertEquals(side, side.toDirection(rtl).toSide(rtl))
        }
        assertNull(SwipeToDismissBoxValue.Settled.toSide(rtl = false))
    }
}
